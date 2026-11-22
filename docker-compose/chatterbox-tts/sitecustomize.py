# Caricato da Python all'avvio (PYTHONPATH=/patches nel compose).
# Il fork chatterbox-v2 carica i checkpoint del multilingual con torch.load
# senza map_location (mtl_tts.py, from_local): salvati per CUDA, su una
# macchina senza GPU falliscono con "Attempting to deserialize object on a
# CUDA device". Qui si imposta cpu come default quando nessuno lo specifica.
# Da togliere se il fork aggiunge map_location.
import torch

_orig_load = torch.load


def _load(*args, **kwargs):
    if "map_location" not in kwargs and len(args) < 2:
        kwargs["map_location"] = torch.device("cpu")
    return _orig_load(*args, **kwargs)


torch.load = _load
