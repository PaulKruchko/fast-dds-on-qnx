#include "fastdds_ipc.h"

#include <cstring>
#include <memory>

#include <fastdds/dds/core/condition/WaitSet.hpp>
#include <fastdds/dds/domain/DomainParticipantFactory.hpp>
#include <fastdds/dds/publisher/Publisher.hpp>
#include <fastdds/dds/publisher/DataWriter.hpp>
#include <fastdds/dds/subscriber/Subscriber.hpp>
#include <fastdds/dds/subscriber/DataReader.hpp>
#include <fastdds/dds/subscriber/SampleInfo.hpp>
#include <fastdds/dds/topic/Topic.hpp>

#include "HelloMsg.h"
#include "HelloMsgPubSubTypes.h"

using namespace eprosima::fastdds::dds;

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

    ReadCondition* req_rc = nullptr;
    ReadCondition* rep_rc = nullptr;

    WaitSet req_ws;
    WaitSet rep_ws;

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
    out.counter   = (uint32_t)in.counter();
    out.t_send_ns = (uint64_t)in.t_send_ns();
    std::memset(out.text, 0, sizeof(out.text));
    std::strncpy(out.text, in.text().c_str(), sizeof(out.text) - 1);
}

extern "C" fd_ipc_handle_t* fd_ipc_create(const char* participant_name)
{
    auto h = std::make_unique<fd_ipc_handle>();

    DomainParticipantQos pqos = PARTICIPANT_QOS_DEFAULT;
    pqos.name(participant_name ? participant_name : "fd_ipc");

    h->participant = DomainParticipantFactory::get_instance()->create_participant(0, pqos);
    if (!h->participant) return nullptr;

    h->type = TypeSupport(new HelloMsgPubSubType());
    h->participant->register_type(h->type);

    h->req_topic = h->participant->create_topic("HelloRequest", h->type->getName(), TOPIC_QOS_DEFAULT);
    h->rep_topic = h->participant->create_topic("HelloReply",   h->type->getName(), TOPIC_QOS_DEFAULT);
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

    h->req_rc = h->req_reader->create_readcondition(
        SampleStateMask::not_read(), ViewStateMask::any(), InstanceStateMask::alive());
    h->rep_rc = h->rep_reader->create_readcondition(
        SampleStateMask::not_read(), ViewStateMask::any(), InstanceStateMask::alive());
    if (!h->req_rc || !h->rep_rc) return nullptr;

    h->req_ws.attach_condition(*h->req_rc);
    h->rep_ws.attach_condition(*h->rep_rc);

    return h.release();
}

extern "C" int fd_ipc_send_request(fd_ipc_handle_t* h, const fd_msg_t* msg)
{
    if (!h || !msg) return -1;
    HelloMsg dds;
    to_dds(*msg, dds);
    return (h->req_writer->write(&dds) == ReturnCode_t::RETCODE_OK) ? 0 : -1;
}

extern "C" int fd_ipc_send_reply(fd_ipc_handle_t* h, const fd_msg_t* msg)
{
    if (!h || !msg) return -1;
    HelloMsg dds;
    to_dds(*msg, dds);
    return (h->rep_writer->write(&dds) == ReturnCode_t::RETCODE_OK) ? 0 : -1;
}

static int take_with_waitset(DataReader* reader, WaitSet& ws, fd_msg_t* out, int timeout_ms)
{
    if (!reader || !out) return -1;

    ConditionSeq active;

    Duration_t timeout = (timeout_ms < 0)
        ? Duration_t::infinite()
        : Duration_t(timeout_ms / 1000, (timeout_ms % 1000) * 1000000);

    ReturnCode_t wrc = ws.wait(active, timeout);
    if (wrc == ReturnCode_t::RETCODE_TIMEOUT) return 0;
    if (wrc != ReturnCode_t::RETCODE_OK) return -1;

    HelloMsg dds;
    SampleInfo info;
    while (reader->take_next_sample(&dds, &info) == ReturnCode_t::RETCODE_OK)
    {
        if (info.valid_data)
        {
            from_dds(dds, *out);
            return 1;
        }
    }
    return 0;
}

extern "C" int fd_ipc_take_request(fd_ipc_handle_t* h, fd_msg_t* out, int timeout_ms)
{
    if (!h) return -1;
    return take_with_waitset(h->req_reader, h->req_ws, out, timeout_ms);
}

extern "C" int fd_ipc_take_reply(fd_ipc_handle_t* h, fd_msg_t* out, int timeout_ms)
{
    if (!h) return -1;
    return take_with_waitset(h->rep_reader, h->rep_ws, out, timeout_ms);
}

extern "C" void fd_ipc_destroy(fd_ipc_handle_t* h)
{
    if (!h) return;

    if (h->req_reader && h->req_rc)
    {
        h->req_ws.detach_condition(*h->req_rc);
        h->req_reader->delete_readcondition(h->req_rc);
    }
    if (h->rep_reader && h->rep_rc)
    {
        h->rep_ws.detach_condition(*h->rep_rc);
        h->rep_reader->delete_readcondition(h->rep_rc);
    }

    if (h->participant)
    {
        h->participant->delete_contained_entities();
        DomainParticipantFactory::get_instance()->delete_participant(h->participant);
    }
    delete h;
}
