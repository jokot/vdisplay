# Toolchain file for MSYS2 UCRT64 on AMD64 Windows.
# Forces CMAKE_SYSTEM_PROCESSOR to AMD64 so the windows.cmake MinHook
# branch selects the installed libMinHook.a instead of the ARM64 detours.
set(CMAKE_SYSTEM_PROCESSOR AMD64)
