/*
 * BridgingHeader.h — Exposes CANClient C++ API to Swift
 *
 * This is the minimal set of headers needed for a third-party app
 * to communicate with the USB CAN driver installed by iCAN.
 */

#import <IOKit/IOKitLib.h>

#ifdef __cplusplus
#import "can_client.h"
#endif

#include "protocol/can.h"
