"""Providers for DriverKit custom rules."""

IigInfo = provider(
    doc = "Information from IIG (IOKit Interface Generator) compilation.",
    fields = {
        "headers": "depset of generated .h header files",
        "sources": "depset of generated .iig.cpp source files",
        "bundle_id": "The bundle identifier used for output subdirectory",
        "include_dir": "The root include directory for generated headers",
    },
)

DriverKitCcInfo = provider(
    doc = "Information from DriverKit C++ compilation.",
    fields = {
        "objects": "depset of compiled .o object files",
        "link_inputs": "depset of all files needed for linking",
    },
)
