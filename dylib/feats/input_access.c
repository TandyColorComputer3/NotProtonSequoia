#include "input_access.h"
#include "../util/log.h"

#include <CoreGraphics/CoreGraphics.h>

// Steam needs this permission for Steam Input. Re-signing Steam silently breaks the existing approval.
void np_input_access_check(void) {
    if (CGPreflightPostEventAccess()) {
        NP_LOG("input access: granted");
        return;
    }
    NP_LOG("input access: missing, asking macOS");
    CGRequestPostEventAccess();
}
