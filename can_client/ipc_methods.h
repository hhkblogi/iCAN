/*
 * ipc_methods.h — IPC method selectors for app ↔ driver communication.
 *
 * Shared between can_client and usb_can_driver.
 */

#pragma once

enum CANDriverMethod {
    kCANDriverMethodOpen = 0,
    kCANDriverMethodClose,
    kCANDriverMethodSendData,
    kCANDriverMethodSetBaudRate,
    kCANDriverMethodWaitForData,
    kCANDriverMethodOpenChannel,    /* scalar[0]=bitrate, scalar[1]=channel → codec.openChannel */
    kCANDriverMethodCloseChannel,   /* scalar[0]=channel → codec.closeChannel */
    kCANDriverMethodCount
};
