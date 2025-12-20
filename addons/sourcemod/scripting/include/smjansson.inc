// Shim include to ensure we use the vendored SMJansson include that is known to compile.
// This shadows any incompatible smjansson.inc earlier in the include search path.
//
// Source: gokz/addons/sourcemod/scripting/include/smjansson.inc

#if defined _gokztop_smjansson_shim_included_
#endinput
#endif
#define _gokztop_smjansson_shim_included_

#include "../../../../gokz/addons/sourcemod/scripting/include/smjansson.inc"


