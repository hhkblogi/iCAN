//
//  iCAN-Bridging-Header.h
//  Bridging header to import IOKit for DriverKit communication
//

#ifndef iCAN_Bridging_Header_h
#define iCAN_Bridging_Header_h

#import <IOKit/IOKitLib.h>
#ifdef __cplusplus
#import "MetricsEngine.hpp"
#import "TestEngines.hpp"
#import "can_client.h"
#endif

// CAN frame types
#include "protocol/can.h"

#endif /* iCAN_Bridging_Header_h */
