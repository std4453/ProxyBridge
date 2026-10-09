// Smoke-test the built DLL through the same dynamic loader as the GUI.
// Does not call Start, open WinDivert, or alter on-disk profiles.
#include <stdio.h>
#include "../gui/api/pb_api.h"

int main(void)
{
    PBApi api;
    if (!PB_Load(&api)) {
        fprintf(stderr, "DLL load/export resolution failed: %lu\n", GetLastError());
        return 1;
    }
    UINT32 rule = api.AddRule("test.exe", "*", "*", "*", PB_PROTO_TCP, PB_ACTION_BLOCK, 0);
    if (!rule || !api.DisableRule(rule) || !api.EnableRule(rule) || !api.DeleteRule(rule)) {
        fprintf(stderr, "DLL rule API smoke test failed\n");
        FreeLibrary(api.dll);
        return 1;
    }
    FreeLibrary(api.dll);
    puts("DLL loaded; all GUI API exports resolved; rule API smoke test passed.");
    return 0;
}
