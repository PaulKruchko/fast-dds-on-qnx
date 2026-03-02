#include "fastdds_ipc.h"

#include <chrono>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <thread>

#include <fastdds/rtps/transport/UDPv4TransportDescriptor.hpp>
#include <fastdds/rtps/common/Locator.hpp>
#include <fastdds/utils/IPLocator.hpp>

#include <fastdds/dds/core/ReturnCode.hpp>
#include <fastdds/dds/core/condition/WaitSet.hpp>
#include <fastdds/dds/core/condition/StatusCondition.hpp>
#include <fastdds/dds/core/status/StatusMask.hpp>

#include <fastdds/dds/domain/DomainParticipant.hpp>
#include <fastdds/dds/domain/DomainParticipantFactory.hpp>
#include <fastdds/dds/domain/qos/DomainParticipantQos.hpp>

#include <fastdds/dds/publisher/Publisher.hpp>
#include <fastdds/dds/publisher/DataWriter.hpp>
#include <fastdds/dds/publisher/qos/DataWriterQos.hpp>

#include <fastdds/dds/subscriber/Subscriber.hpp>
#include <fastdds/dds/subscriber/DataReader.hpp>
#include <fastdds/dds/subscriber/SampleInfo.hpp>
#include <fastdds/dds/subscriber/qos/DataReaderQos.hpp>

#include <fastdds/dds/topic/Topic.hpp>

#include "ipcbench_idl.hpp"
#include "ipcbench_idl_pubsub.hpp"

using namespace eprosima::fastdds::dds;

// DDS spec ReturnCode values (stable across DDS implementations)
static inline int rc_int(ReturnCode_t rc)
{
    return static_cast<int>(rc);
}

static constexpr int DDS_RETCODE_OK      = 0;
static constexpr int DDS_RETCODE_TIMEOUT = 10;

static Duration_t make_timeout(int timeout_ms)
{
    if (timeout_ms < 0)
    {
        // "Infinite enough" (~68 years) without relying on API-specific infinite()
        return Duration_t{std::numeric_limits<int32_t>::max(), 0u};
    }

    const int32_t sec  = static_cast<int32_t>(timeout_ms / 1000);
    const uint32_t nsec = static_cast<uint32_t>(timeout_ms % 1000) * 1000000u;
    return Duration_t{sec, nsec};
}

struct fd_ipc_handle
{
    DomainParticipant* participant = nullptr;
    Publisher* pub = nullptr;
    Subscriber* sub = nullptr;

    Topic* req_topic = nullptr;
    Topic* rep_topic = nullptr;

    DataWriter* req_writer = nullptr;
    DataWriter* rep_writer = nullptr;

    DataReader* req_reader = nullptr;
    DataReader* rep_reader = nullptr;

    // WaitSet-based receive
    WaitSet req_waitset;
    WaitSet rep_waitset;
    StatusCondition* req_sc = nullptr;
    StatusCondition* rep_sc = nullptr;

    TypeSupport type;
};

static void force_reliable_keep_last_32(DataWriterQos& wqos)
{
    wqos.reliability().kind = RELIABLE_RELIABILITY_QOS;
    wqos.history().kind = KEEP_LAST_HISTORY_QOS;
    wqos.history().depth = 32;
}

static void force_reliable_keep_last_32(DataReaderQos& rqos)
{
    rqos.reliability().kind = RELIABLE_RELIABILITY_QOS;
    rqos.history().kind = KEEP_LAST_HISTORY_QOS;
    rqos.history().depth = 32;
}

static void to_dds(const fd_msg_t& in, HelloMsg& out)
{
    out.counter(in.counter);
    out.t_send_ns(in.t_send_ns);
    out.text(in.text);
}

static void from_dds(const HelloMsg& in, fd_msg_t& out)
{
    out.counter   = static_cast<uint32_t>(in.counter());
    out.t_send_ns = static_cast<uint64_t>(in.t_send_ns());
    std::memset(out.text, 0, sizeof(out.text));
    std::strncpy(out.text, in.text().c_str(), sizeof(out.text) - 1);
}

static void configure_participant_qos_udp_only(DomainParticipantQos& pqos)
{
    // Disable builtin transports (prevents SHM)
    pqos.transport().use_builtin_transports = false;
    pqos.transport().user_transports.clear();

    // Force UDPv4 transport
    pqos.transport().user_transports.push_back(
        std::make_shared<eprosima::fastdds::rtps::UDPv4TransportDescriptor>());

    // Avoid multicast discovery; use loopback unicast discovery
    pqos.wire_protocol().builtin.avoid_builtin_multicast = true;
    pqos.wire_protocol().builtin.metatrafficMulticastLocatorList.clear();
    pqos.wire_protocol().builtin.metatrafficUnicastLocatorList.clear();
    pqos.wire_protocol().builtin.initialPeersList.clear();

    eprosima::fastdds::rtps::Locator_t meta_uc;
    eprosima::fastdds::rtps::IPLocator::setIPv4(meta_uc, 127, 0, 0, 1);
    meta_uc.port = 7412;

    pqos.wire_protocol().builtin.metatrafficUnicastLocatorList.push_back(meta_uc);
    pqos.wire_protocol().builtin.initialPeersList.push_back(meta_uc);
}

// Returns: 1 = got sample, 0 = timeout, -1 = error
static int take_with_waitset(DataReader* reader, WaitSet& ws, fd_msg_t* out, int timeout_ms)
{
    if (!reader || !out) return -1;

    HelloMsg dds;
    SampleInfo info;

    // Drain any already-queued data first
    while (rc_int(reader->take_next_sample(&dds, &info)) == DDS_RETCODE_OK)
    {
        if (info.valid_data)
        {
            from_dds(dds, *out);
            return 1;
        }
    }

    if (timeout_ms == 0) return 0;

    ConditionSeq active_conditions;
    ReturnCode_t wrc = ws.wait(active_conditions, make_timeout(timeout_ms));

    const int w = rc_int(wrc);
    if (w == DDS_RETCODE_TIMEOUT) return 0;
    if (w != DDS_RETCODE_OK) return -1;

    // We were signaled; try to take the sample(s)
    while (rc_int(reader->take_next_sample(&dds, &info)) == DDS_RETCODE_OK)
    {
        if (info.valid_data)
        {
            from_dds(dds, *out);
            return 1;
        }
    }

    // Spurious wake or no valid data
    return 0;
}

extern "C" fd_ipc_handle_t* fd_ipc_create(const char* participant_name)
{
    auto h = std::make_unique<fd_ipc_handle>();

    DomainParticipantQos pqos = PARTICIPANT_QOS_DEFAULT;
    pqos.name(participant_name ? participant_name : "fd_ipc");

    // ---- Force UDP-only, disable builtin transports (prevents SHM) ----
    configure_participant_qos_udp_only(pqos);

    h->participant = DomainParticipantFactory::get_instance()->create_participant(0, pqos);
    if (!h->participant) return nullptr;

    h->type = TypeSupport(new HelloMsgPubSubType());
    h->participant->register_type(h->type);

    const std::string type_name = h->type->get_name();

    h->req_topic = h->participant->create_topic("HelloRequest", type_name, TOPIC_QOS_DEFAULT);
    h->rep_topic = h->participant->create_topic("HelloReply",   type_name, TOPIC_QOS_DEFAULT);
    if (!h->req_topic || !h->rep_topic) return nullptr;

    h->pub = h->participant->create_publisher(PUBLISHER_QOS_DEFAULT);
    h->sub = h->participant->create_subscriber(SUBSCRIBER_QOS_DEFAULT);
    if (!h->pub || !h->sub) return nullptr;

    DataWriterQos wqos = DATAWRITER_QOS_DEFAULT;
    h->pub->get_default_datawriter_qos(wqos);
    force_reliable_keep_last_32(wqos);

    h->req_writer = h->pub->create_datawriter(h->req_topic, wqos);
    h->rep_writer = h->pub->create_datawriter(h->rep_topic, wqos);
    if (!h->req_writer || !h->rep_writer) return nullptr;

    DataReaderQos rqos = DATAREADER_QOS_DEFAULT;
    h->sub->get_default_datareader_qos(rqos);
    force_reliable_keep_last_32(rqos);

    h->req_reader = h->sub->create_datareader(h->req_topic, rqos);
    h->rep_reader = h->sub->create_datareader(h->rep_topic, rqos);
    if (!h->req_reader || !h->rep_reader) return nullptr;

    // ---- WaitSet wiring (StatusCondition -> WaitSet) ----
    h->req_sc = &h->req_reader->get_statuscondition();
    h->req_sc->set_enabled_statuses(StatusMask::data_available());
    h->req_waitset.attach_condition(*h->req_sc);

    h->rep_sc = &h->rep_reader->get_statuscondition();
    h->rep_sc->set_enabled_statuses(StatusMask::data_available());
    h->rep_waitset.attach_condition(*h->rep_sc);

    return h.release();
}

extern "C" int fd_ipc_send_request(fd_ipc_handle_t* h, const fd_msg_t* msg)
{
    if (!h || !msg) return -1;
    HelloMsg dds;
    to_dds(*msg, dds);
    return (rc_int(h->req_writer->write(&dds)) == DDS_RETCODE_OK) ? 0 : -1;
}

extern "C" int fd_ipc_send_reply(fd_ipc_handle_t* h, const fd_msg_t* msg)
{
    if (!h || !msg) return -1;
    HelloMsg dds;
    to_dds(*msg, dds);
    return (rc_int(h->rep_writer->write(&dds)) == DDS_RETCODE_OK) ? 0 : -1;
}

extern "C" int fd_ipc_take_request(fd_ipc_handle_t* h, fd_msg_t* out, int timeout_ms)
{
    if (!h) return -1;
    return take_with_waitset(h->req_reader, h->req_waitset, out, timeout_ms);
}

extern "C" int fd_ipc_take_reply(fd_ipc_handle_t* h, fd_msg_t* out, int timeout_ms)
{
    if (!h) return -1;
    return take_with_waitset(h->rep_reader, h->rep_waitset, out, timeout_ms);
}

extern "C" void fd_ipc_destroy(fd_ipc_handle_t* h)
{
    if (!h) return;

    // Detach conditions (safe cleanup)
    if (h->req_sc) h->req_waitset.detach_condition(*h->req_sc);
    if (h->rep_sc) h->rep_waitset.detach_condition(*h->rep_sc);

    if (h->participant)
    {
        h->participant->delete_contained_entities();
        DomainParticipantFactory::get_instance()->delete_participant(h->participant);
    }
    delete h;
}
