#!/usr/bin/env bash
# Prova in locale la configurazione lan-upload di Traefik (HOME-53) prima del
# deploy: avvia Traefik e rclone in Docker con certificato e password finti,
# carica i file dinamici VERI del repo e controlla che
#   - il file provider carichi tutti i router (un errore di template in
#     lan-upload.yml farebbe sparire anche quelli di dynamic.yml);
#   - venga servito il certificato di lan-upload;
#   - PUT con credenziali giuste passi e tutto il resto venga rifiutato.
# Non tocca nulla fuori da una cartella temporanea e dalla rete Docker
# home53lt, che rimuove alla fine. Serve solo Docker e openssl.
#
# Uso: scripts/lan-upload-test.sh   (dalla radice del repo)
# Le versioni delle immagini vanno tenute allineate ai compose.
set -euo pipefail

TRAEFIK_IMAGE=traefik:v3.7.10
RCLONE_IMAGE=docker.io/rclone/rclone:1.75.2
CURL_IMAGE=docker.io/curlimages/curl:8.17.0
SRC=docker-compose/traefik
# Password finte, valide solo dentro questo test.
TEST_PW=lanuptest
WRONG_PW=sbagliata

T=$(mktemp -d)
cleanup() {
  docker rm -f lanup-traefik lanup-webdav >/dev/null 2>&1 || true
  docker network rm home53lt >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT

mkdir -p "$T/dyn" "$T/certs" "$T/consume/rakazo"
cp "$SRC"/dynamic/*.yml "$T/dyn/"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj "/CN=lan-upload-test" -keyout "$T/key.pem" -out "$T/certs/lan-upload.crt" 2>/dev/null

docker network create home53lt >/dev/null
docker run -d --rm --name lanup-webdav --network home53lt --user "$(id -u):$(id -g)" \
  -v "$T/consume:/consume" "$RCLONE_IMAGE" serve webdav /consume --addr=:8020 >/dev/null

# Nel test il backend è il container rclone e il client è sulla rete Docker:
# cambiano solo URL del servizio e IP consentito, il resto è il file reale.
SUB=$(docker network inspect home53lt -f '{{(index .IPAM.Config 0).Subnet}}')
sed -i "s#http://192.168.10.119:8020#http://lanup-webdav:8020#; s#192.168.10.118/32#$SUB#" "$T/dyn/lan-upload.yml"

docker run -d --rm --name lanup-traefik --network home53lt \
  -e LAN_UPLOAD_TLS_KEY_B64="$(base64 -w0 "$T/key.pem")" \
  -e LAN_UPLOAD_RAKAZO_HTPASSWD="rakazo:$(openssl passwd -apr1 "$TEST_PW")" \
  -v "$T/dyn:/etc/traefik/dynamic:ro" -v "$T/certs:/etc/traefik/certs:ro" "$TRAEFIK_IMAGE" \
  --providers.file.directory=/etc/traefik/dynamic --entrypoints.web.address=:80 \
  --entrypoints.lan-upload.address=:8099 --entrypoints.lan-upload.http.tls=true \
  --api=true --api.insecure=true >/dev/null
sleep 4

fail=0
check() { # descrizione, atteso, ottenuto
  if [ "$2" = "$3" ]; then echo "ok    $1 ($3)"; else echo "ERRORE $1: atteso $2, ottenuto $3"; fail=1; fi
}

if docker logs lanup-traefik 2>&1 | grep -q "Error while building configuration"; then
  echo "ERRORE: il file provider non si carica:"; docker logs lanup-traefik 2>&1 | grep "Error while building"; exit 1
fi

curl_() { docker run --rm --network home53lt -v "$T:/w:ro" "$CURL_IMAGE" "$@"; }
TIP=$(docker inspect lanup-traefik -f '{{(index .NetworkSettings.Networks "home53lt").IPAddress}}')
URL="https://$TIP:8099"
# -k: il certificato di test non ha l'IP del container nel SAN. Quale
# certificato viene servito lo controlla openssl più sotto.
code() { curl_ -s -o /dev/null -w '%{http_code}' -k "$@"; }

routers=$(curl_ -s "http://$TIP:8080/api/http/routers" | python3 -c \
  "import sys,json; print(sum(1 for r in json.load(sys.stdin) if r['name'].endswith('@file') and r['status']=='enabled'))")
expected=$(grep -cE '^    [a-z0-9-]+:$' <(sed -n '/^  routers:/,/^  [a-z]/p' "$SRC"/dynamic/*.yml) || true)
check "router del file provider attivi" "$expected" "$routers"

subject=$(echo | openssl s_client -connect "$TIP:8099" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)
check "certificato servito" "subject=CN=lan-upload-test" "$subject"

# Il container curl gira come utente non root: deve poter leggere il file.
chmod 755 "$T"
printf 'test' > "$T/doc.txt" && chmod 644 "$T/doc.txt"
check "PUT nella propria cartella"   201 "$(code -u "rakazo:$TEST_PW" -T /w/doc.txt "$URL/rakazo/doc.txt")"
check "PUT con password sbagliata"   401 "$(code -u "rakazo:$WRONG_PW" -T /w/doc.txt "$URL/rakazo/x.txt")"
check "PUT senza credenziali"        401 "$(code -T /w/doc.txt "$URL/rakazo/x.txt")"
check "PUT in un'altra cartella"     404 "$(code -u "rakazo:$TEST_PW" -T /w/doc.txt "$URL/altro/x.txt")"
check "PUT fuori dalla cartella (..)" 404 "$(code -u "rakazo:$TEST_PW" -T /w/doc.txt --path-as-is "$URL/rakazo/../x.txt")"
check "PUT fuori dalla cartella (%2e)" 404 "$(code -u "rakazo:$TEST_PW" -T /w/doc.txt --path-as-is "$URL/rakazo/%2e%2e/x.txt")"
check "GET di un file caricato"      404 "$(code -u "rakazo:$TEST_PW" "$URL/rakazo/doc.txt")"
check "PROPFIND (elenco)"            404 "$(code -u "rakazo:$TEST_PW" -X PROPFIND "$URL/rakazo/")"
check "DELETE"                       404 "$(code -u "rakazo:$TEST_PW" -X DELETE "$URL/rakazo/doc.txt")"
check "file arrivato in consume/rakazo" yes "$([ -f "$T/consume/rakazo/doc.txt" ] && echo yes || echo no)"

[ "$fail" = 0 ] && echo "Tutti i controlli passati." || { echo "Qualche controllo è fallito."; exit 1; }
