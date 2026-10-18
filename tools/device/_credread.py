"""In-process Windows Credential Manager reader (CredReadW). Never prints values."""
import ctypes, ctypes.wintypes as w

class _CRED(ctypes.Structure):
    _fields_ = [("Flags", w.DWORD), ("Type", w.DWORD), ("TargetName", w.LPWSTR),
                ("Comment", w.LPWSTR), ("LastWritten", w.FILETIME), ("CredentialBlobSize", w.DWORD),
                ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)), ("Persist", w.DWORD),
                ("AttributeCount", w.DWORD), ("Attributes", ctypes.c_void_p),
                ("TargetAlias", w.LPWSTR), ("UserName", w.LPWSTR)]

def cred_read(target: str) -> bytes:
    a = ctypes.windll.advapi32
    a.CredReadW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.POINTER(ctypes.POINTER(_CRED))]
    p = ctypes.POINTER(_CRED)()
    if not a.CredReadW(target, 1, 0, ctypes.byref(p)):
        raise KeyError("credential not found: " + target)
    try:
        c = p.contents
        return bytes(bytearray(c.CredentialBlob[:c.CredentialBlobSize]))
    finally:
        a.CredFree(p)
