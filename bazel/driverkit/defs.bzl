"""Public API for DriverKit custom Bazel rules."""

load("//bazel/driverkit:iig.bzl", _iig_library = "iig_library")
load("//bazel/driverkit:driverkit_cc.bzl", _driverkit_cc_library = "driverkit_cc_library")
load("//bazel/driverkit:driverkit_extension.bzl", _driverkit_extension = "driverkit_extension")
load("//bazel/driverkit:ios_application_with_dext.bzl", _ios_application_with_dext = "ios_application_with_dext")
load("//bazel/driverkit:providers.bzl", _DriverKitCcInfo = "DriverKitCcInfo", _IigInfo = "IigInfo")

iig_library = _iig_library
driverkit_cc_library = _driverkit_cc_library
driverkit_extension = _driverkit_extension
ios_application_with_dext = _ios_application_with_dext
IigInfo = _IigInfo
DriverKitCcInfo = _DriverKitCcInfo
