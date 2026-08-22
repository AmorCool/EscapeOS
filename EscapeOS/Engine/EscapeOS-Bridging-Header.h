//
//  EscapeOS-Bridging-Header.h
//  EscapeOS
//
//  Exposes the bad_query primitive and the RPPairing tunnel context to Swift.
//

#ifndef EscapeOS_Bridging_Header_h
#define EscapeOS_Bridging_Header_h

#include "bad_query.h"
#include "zip_crypto.h"
#import "../Tunnel/TunnelContext.h"

// MHA branch: MCM integration layer (bad_query + MobileHouseArrest)
#import "MCM/MCMBridge.h"
#import "MCM/BQMCMIntegration.h"

#endif /* EscapeOS_Bridging_Header_h */
