import ctypes
import subprocess
import time
from ctypes import wintypes

from PIL import ImageGrab

user32 = ctypes.windll.user32
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    user32.SetProcessDPIAware()

SW_RESTORE = 9


class RECT(ctypes.Structure):
    _fields_ = [
        ("left", ctypes.c_long),
        ("top", ctypes.c_long),
        ("right", ctypes.c_long),
        ("bottom", ctypes.c_long),
    ]


user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
user32.GetWindowRect.restype = wintypes.BOOL
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.ShowWindow.restype = wintypes.BOOL
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.SetForegroundWindow.restype = wintypes.BOOL
user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextLengthW.restype = ctypes.c_int
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.restype = ctypes.c_int
user32.GetWindowThreadProcessId.argtypes = [
    wintypes.HWND,
    ctypes.POINTER(wintypes.DWORD),
]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD


out = subprocess.check_output(
    [
        "powershell",
        "-NoProfile",
        "-Command",
        "Get-Process lvpai_ftp_client | Select-Object -ExpandProperty Id",
    ],
    text=True,
)
pids = {int(x) for x in out.split() if x.strip().isdigit()}
print("pids", pids)

EnumWindowsProc = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
target = None


def callback(hwnd, _lparam):
    global target
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    if pid.value not in pids:
        return True
    length = user32.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buf, length + 1)
    print(
        "hwnd",
        hwnd,
        "title",
        buf.value,
        "visible",
        bool(user32.IsWindowVisible(hwnd)),
    )
    if buf.value:
        target = hwnd
    return True


user32.EnumWindows(EnumWindowsProc(callback), 0)
if not target:
    raise SystemExit("no window")

user32.ShowWindow(target, SW_RESTORE)
user32.SetForegroundWindow(target)
time.sleep(0.5)
rect = RECT()
user32.GetWindowRect(target, ctypes.byref(rect))
print("rect", rect.left, rect.top, rect.right, rect.bottom)
w = rect.right - rect.left
h = rect.bottom - rect.top
if w <= 1 or h <= 1:
    raise SystemExit(f"bad rect size {w}x{h}")
img = ImageGrab.grab(
    bbox=(rect.left, rect.top, rect.right, rect.bottom),
    all_screens=True,
)
path = r"C:\Users\Dexte\Desktop\IDEA_project\creative-travel-shoot\ftp-and-print-tool\prototype\flutter-variant-a-capture.png"
img.save(path)
print("saved", path, img.size)
