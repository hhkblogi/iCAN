#include "can_schema.h"

#include <fstream>
#include <memory>
#include <string>
#include <string_view>
#include <cstring>
#include <vector>

#include <gtest/gtest.h>
#include "rules_cc/cc/runfiles/runfiles.h"

namespace {

using rules_cc::cc::runfiles::Runfiles;

canfd_frame makeFrame() {
    canfd_frame frame = {};
    frame.can_id = 0x123;
    frame.len = 8;
    frame.flags = 0;
    return frame;
}

std::string_view viewOf(const char* ptr, size_t len) {
    return ptr == nullptr ? std::string_view() : std::string_view(ptr, len);
}

std::string loadFixtureDBC() {
    std::string error;
    std::unique_ptr<Runfiles> runfiles(Runfiles::CreateForTest(&error));
    EXPECT_NE(runfiles, nullptr) << error;

    const char* candidates[] = {
        "_main/can_schema/testdata/demo.dbc",
        "ican/can_schema/testdata/demo.dbc",
    };

    for (const char* candidate : candidates) {
        const std::string path = runfiles->Rlocation(candidate);
        if (path.empty()) {
            continue;
        }

        std::ifstream input(path);
        if (!input.good()) {
            continue;
        }

        return std::string(
            std::istreambuf_iterator<char>(input),
            std::istreambuf_iterator<char>()
        );
    }

    ADD_FAILURE() << "failed to resolve can_schema/testdata/demo.dbc from Bazel runfiles";
    return {};
}

}  // namespace

TEST(CANSchemaTest, LoadsFixtureDBCTextFromFile) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();

    ASSERT_FALSE(dbc.empty());
    EXPECT_TRUE(schema.loadDBCText(dbc.c_str()));
    EXPECT_TRUE(schema.hasSchema());
}

TEST(CANSchemaTest, RejectsDBCWithoutMessages) {
    CANSchema schema;
    const char* dbc = "VERSION \"1.0\"\n\nNS_ :\n\nBS_:\n\nBU_: ECM\n";

    EXPECT_FALSE(schema.loadDBCText(dbc));
    EXPECT_FALSE(schema.hasSchema());
    EXPECT_STREQ(schema.lastError(), "failed to create can_schema handle");
}

TEST(CANSchemaTest, RejectsSignalsThatExceedMessageDLC) {
    CANSchema schema;
    const char* dbc =
        "VERSION \"1.0\"\n\n"
        "NS_ :\n\n"
        "BS_:\n\n"
        "BU_: ECM\n\n"
        "BO_ 1 Msg : 8 ECM\n"
        " SG_ Bad : 63|2@1+ (1,0) [0|3] \"\" ECM\n";

    EXPECT_FALSE(schema.loadDBCText(dbc));
    EXPECT_FALSE(schema.hasSchema());
}

TEST(CANSchemaTest, AcceptsNonUtf8DBCBytes) {
    CANSchema schema;
    std::vector<uint8_t> dbc = {
        'V','E','R','S','I','O','N',' ','"','1','.','0','"','\n','\n',
        'N','S','_',' ',':','\n','\n',
        'B','S','_',':','\n','\n',
        'B','U','_',':',' ','E','C','M','\n','\n',
        'B','O','_',' ','2','9','1',' ','D','e','m','o',' ',':',' ','8',' ','E','C','M','\n',
        ' ','S','G','_',' ','T','e','m','p',' ',':',' ','0','|','8','@','1','+',' ',
        '(','1',',','0',')',' ','[','0','|','2','5','5',']',' ','"'
    };
    dbc.push_back(0xB0);
    dbc.insert(dbc.end(), {'C','"',' ','E','C','M','\n'});

    EXPECT_TRUE(schema.loadDBCText(dbc.data(), dbc.size()));
    EXPECT_TRUE(schema.hasSchema());
}

TEST(CANSchemaTest, FailedReloadClearsPreviousSchema) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));
    ASSERT_TRUE(schema.hasSchema());

    const char* invalid = "VERSION \"1.0\"\n\nNS_ :\n\nBS_:\n\nBU_: ECM\n";
    EXPECT_FALSE(schema.loadDBCText(invalid));
    EXPECT_FALSE(schema.hasSchema());

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[2] = {};
    size_t signalCount = 99;

    const int32_t status = schema.decode(makeFrame(), &message, signals, 2, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_NOT_READY);
    EXPECT_FALSE(message.matched);
    EXPECT_EQ(signalCount, 0u);
    EXPECT_STREQ(schema.lastError(), "schema is not loaded");
}

TEST(CANSchemaTest, DecodeReturnsSignalValuesForLoadedSchema) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 291;
    frame.data[0] = 0x34;
    frame.data[1] = 0x12;
    frame.data[2] = 100;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[4] = {};
    size_t signalCount = 99;

    const int32_t status = schema.decode(frame, &message, signals, 4, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_OK);
    EXPECT_TRUE(message.matched);
    EXPECT_EQ(signalCount, 2u);
    EXPECT_EQ(viewOf(message.messageName, message.messageNameLength), "Demo");
    EXPECT_EQ(viewOf(signals[0].name, signals[0].nameLength), "Speed");
    EXPECT_EQ(viewOf(signals[0].unit, signals[0].unitLength), "km/h");
    EXPECT_EQ(signals[0].value, 0x1234);
    EXPECT_EQ(viewOf(signals[1].name, signals[1].nameLength), "Temp");
    EXPECT_EQ(viewOf(signals[1].unit, signals[1].unitLength), "C");
    EXPECT_DOUBLE_EQ(signals[1].value, 10.0);
    EXPECT_STREQ(schema.lastError(), "");
}

TEST(CANSchemaTest, DecodeReturnsChoiceDisplayLabel) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 0x80000000u | 419385573u;
    frame.data[0] = 7;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[4] = {};
    size_t signalCount = 0;

    const int32_t status = schema.decode(frame, &message, signals, 4, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_OK);
    ASSERT_EQ(signalCount, 1u);
    EXPECT_EQ(viewOf(signals[0].name, signals[0].nameLength), "Mode");
    EXPECT_EQ(viewOf(signals[0].displayValue, signals[0].displayValueLength), "Active");
}

TEST(CANSchemaTest, DecodeReturnsFloatSignalValues) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 800;
    frame.data[0] = 0x00;
    frame.data[1] = 0x00;
    frame.data[2] = 0x80;
    frame.data[3] = 0x3f;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[2] = {};
    size_t signalCount = 0;

    const int32_t status = schema.decode(frame, &message, signals, 2, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_OK);
    EXPECT_TRUE(message.matched);
    EXPECT_EQ(viewOf(message.messageName, message.messageNameLength), "FloatStatus");
    ASSERT_EQ(signalCount, 1u);
    EXPECT_EQ(viewOf(signals[0].name, signals[0].nameLength), "Ratio");
    EXPECT_DOUBLE_EQ(signals[0].value, 1.0);
}

TEST(CANSchemaTest, MoveConstructionPreservesLoadedSchema) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    CANSchema moved(std::move(schema));
    EXPECT_TRUE(moved.hasSchema());
    EXPECT_FALSE(schema.hasSchema());

    canfd_frame frame = makeFrame();
    frame.can_id = 291;
    frame.data[0] = 0x34;
    frame.data[1] = 0x12;
    frame.data[2] = 100;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[4] = {};
    size_t signalCount = 0;

    const int32_t status = moved.decode(frame, &message, signals, 4, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_OK);
    EXPECT_TRUE(message.matched);
    EXPECT_EQ(viewOf(message.messageName, message.messageNameLength), "Demo");
    EXPECT_EQ(signalCount, 2u);
}

TEST(CANSchemaTest, DecodeReportsNoMatchForUnknownFrame) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 0x456;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[1] = {};
    size_t signalCount = 5;

    const int32_t status = schema.decode(frame, &message, signals, 1, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_NO_MATCH);
    EXPECT_FALSE(message.matched);
    EXPECT_EQ(signalCount, 0u);
    EXPECT_STREQ(schema.lastError(), "");
}

TEST(CANSchemaTest, DecodeReportsSmallSignalBuffer) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 291;
    frame.data[0] = 0x34;
    frame.data[1] = 0x12;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[1] = {};
    size_t signalCount = 0;

    const int32_t status = schema.decode(frame, &message, signals, 0, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_BUFFER_TOO_SMALL);
    EXPECT_TRUE(message.matched);
    EXPECT_EQ(signalCount, 2u);
    EXPECT_STREQ(schema.lastError(), "decoded signal buffer is too small");
}

TEST(CANSchemaTest, DecodeAllowsNullSignalBufferProbe) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 291;
    frame.data[0] = 0x34;
    frame.data[1] = 0x12;
    frame.data[2] = 100;

    CANSchemaDecodedMessage message;
    size_t signalCount = 99;

    const int32_t status = schema.decode(frame, &message, nullptr, 0, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_BUFFER_TOO_SMALL);
    EXPECT_TRUE(message.matched);
    EXPECT_EQ(signalCount, 2u);
    EXPECT_STREQ(schema.lastError(), "decoded signal buffer is too small");
}

TEST(CANSchemaTest, DecodeRejectsShortPayloadForFixtureMessage) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 291;
    frame.len = 2;
    frame.data[0] = 0x34;
    frame.data[1] = 0x12;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[4] = {};
    size_t signalCount = 0;

    const int32_t status = schema.decode(frame, &message, signals, 4, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_INVALID_ARGUMENT);
    EXPECT_FALSE(message.matched);
    EXPECT_EQ(signalCount, 0u);
    EXPECT_STREQ(schema.lastError(), "frame payload shorter than DBC message DLC");
}

TEST(CANSchemaTest, DecodeBatteryMessageFromFixtureFile) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 512;
    frame.data[0] = 0x10;
    frame.data[1] = 0x27;
    frame.data[2] = 0x9c;
    frame.data[3] = 0xff;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[4] = {};
    size_t signalCount = 0;

    const int32_t status = schema.decode(frame, &message, signals, 4, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_OK);
    EXPECT_TRUE(message.matched);
    EXPECT_EQ(viewOf(message.messageName, message.messageNameLength), "Battery");
    ASSERT_EQ(signalCount, 2u);
    EXPECT_EQ(viewOf(signals[0].name, signals[0].nameLength), "Voltage");
    EXPECT_DOUBLE_EQ(signals[0].value, 100.0);
    EXPECT_EQ(viewOf(signals[1].name, signals[1].nameLength), "Current");
    EXPECT_DOUBLE_EQ(signals[1].value, -10.0);
}

TEST(CANSchemaTest, DecodeExtendedMessageFromFixtureFile) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 0x80000000u | 419385573u;
    frame.data[0] = 7;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[4] = {};
    size_t signalCount = 0;

    const int32_t status = schema.decode(frame, &message, signals, 4, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_OK);
    EXPECT_TRUE(message.matched);
    EXPECT_EQ(viewOf(message.messageName, message.messageNameLength), "ExtStatus");
    ASSERT_EQ(signalCount, 1u);
    EXPECT_EQ(viewOf(signals[0].name, signals[0].nameLength), "Mode");
    EXPECT_DOUBLE_EQ(signals[0].value, 7.0);
}

TEST(CANSchemaTest, DecodeReturnsOnlyActiveMultiplexedSignals) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 600;
    frame.data[0] = 0;
    frame.data[1] = 88;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[4] = {};
    size_t signalCount = 0;

    const int32_t status = schema.decode(frame, &message, signals, 4, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_OK);
    EXPECT_TRUE(message.matched);
    EXPECT_EQ(viewOf(message.messageName, message.messageNameLength), "MultiStatus");
    ASSERT_EQ(signalCount, 2u);
    EXPECT_EQ(viewOf(signals[0].name, signals[0].nameLength), "Page");
    EXPECT_EQ(viewOf(signals[0].displayValue, signals[0].displayValueLength), "Drive");
    EXPECT_EQ(viewOf(signals[1].name, signals[1].nameLength), "DriveSpeed");
    EXPECT_DOUBLE_EQ(signals[1].value, 88.0);
}

TEST(CANSchemaTest, DecodeSwitchesMultiplexedBranch) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 600;
    frame.data[0] = 1;
    frame.data[1] = 93;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[4] = {};
    size_t signalCount = 0;

    const int32_t status = schema.decode(frame, &message, signals, 4, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_OK);
    ASSERT_EQ(signalCount, 2u);
    EXPECT_EQ(viewOf(signals[0].name, signals[0].nameLength), "Page");
    EXPECT_EQ(viewOf(signals[0].displayValue, signals[0].displayValueLength), "Thermal");
    EXPECT_EQ(viewOf(signals[1].name, signals[1].nameLength), "CoolantTemp");
    EXPECT_DOUBLE_EQ(signals[1].value, 93.0);
}

TEST(CANSchemaTest, DecodeRejectsRemoteAndErrorFrames) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    for (const uint32_t flag : {CAN_RTR_FLAG, CAN_ERR_FLAG}) {
        canfd_frame frame = makeFrame();
        frame.can_id = flag | 291u;
        frame.data[0] = 0x34;
        frame.data[1] = 0x12;
        frame.data[2] = 100;

        CANSchemaDecodedMessage message;
        CANSchemaDecodedSignal signals[2] = {};
        size_t signalCount = 99;

        const int32_t status = schema.decode(frame, &message, signals, 2, &signalCount);

        EXPECT_EQ(status, ICAN_SCHEMA_STATUS_INVALID_ARGUMENT);
        EXPECT_FALSE(message.matched);
        EXPECT_EQ(signalCount, 0u);
        EXPECT_STREQ(schema.lastError(), "RTR and error CAN frames are not decodable");
    }
}

TEST(CANSchemaTest, DecodeRejectsTruncatedZeroSignalMessage) {
    CANSchema schema;
    const std::string dbc = loadFixtureDBC();
    ASSERT_FALSE(dbc.empty());
    ASSERT_TRUE(schema.loadDBCText(dbc.c_str()));

    canfd_frame frame = makeFrame();
    frame.can_id = 700;
    frame.len = 0;

    CANSchemaDecodedMessage message;
    size_t signalCount = 99;

    const int32_t status = schema.decode(frame, &message, nullptr, 0, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_INVALID_ARGUMENT);
    EXPECT_FALSE(message.matched);
    EXPECT_EQ(signalCount, 0u);
    EXPECT_STREQ(schema.lastError(), "frame payload shorter than DBC message DLC");
}

TEST(CANSchemaTest, DecodeReportsMissingSchema) {
    CANSchema schema;

    CANSchemaDecodedMessage message;
    CANSchemaDecodedSignal signals[2] = {};
    size_t signalCount = 1;

    const int32_t status = schema.decode(makeFrame(), &message, signals, 2, &signalCount);

    EXPECT_EQ(status, ICAN_SCHEMA_STATUS_NOT_READY);
    EXPECT_FALSE(message.matched);
    EXPECT_EQ(signalCount, 0u);
    EXPECT_STREQ(schema.lastError(), "schema is not loaded");
}
