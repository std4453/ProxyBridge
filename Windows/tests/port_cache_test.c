// Exercise the real packet loop with synthetic packets; no driver or admin needed.
// Only receive/send and rule evaluation are replaced. Parsing, rewriting,
// connection tracking and the IPv4 PID cache use production code.
#define WINDIVERTEXPORT extern
#include "pb_internal.h"

static BOOL mock_recv(HANDLE, PVOID, UINT, UINT *, WINDIVERT_ADDRESS *);
static BOOL mock_send(HANDLE, const VOID *, UINT, UINT *, const WINDIVERT_ADDRESS *);
static RuleAction mock_rule(UINT32, UINT16, UINT32, UINT16, BOOL, DWORD *, UINT32 *);
static RuleAction mock_rule6(const UINT8 *, UINT16, const UINT8 *, UINT16, BOOL, DWORD *, UINT32 *);
#define WinDivertRecv mock_recv
#define WinDivertSend mock_send
#define check_process_rule mock_rule
#define check_process_rule_v6 mock_rule6
#ifndef PB_PACKET_SOURCE
#define PB_PACKET_SOURCE "../src/ProxyBridge.c"
#endif
#include PB_PACKET_SOURCE

static unsigned char input[80], output[80];
static UINT input_len, output_len;
static int receives, sends, evaluations, failures, checks;
static RuleAction verdict;
static const UINT16 test_port = 53123;

#define CHECK(expr) do { checks++; if (!(expr)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); failures++; \
} } while (0)

static BOOL mock_recv(HANDLE h, PVOID p, UINT cap, UINT *len, WINDIVERT_ADDRESS *a)
{
    if (receives++) {
        running = FALSE;
        SetLastError(ERROR_INVALID_HANDLE);
        return FALSE;
    }
    memcpy(p, input, input_len);
    *len = input_len;
    memset(a, 0, sizeof(*a));
    a->Outbound = TRUE;
    return TRUE;
}

static BOOL mock_send(HANDLE h, const VOID *p, UINT len, UINT *sent, const WINDIVERT_ADDRESS *a)
{
    CHECK(len <= sizeof(output));
    memcpy(output, p, len);
    output_len = len;
    sends++;
    return TRUE;
}

static RuleAction mock_rule(UINT32 src, UINT16 sp, UINT32 dst, UINT16 dp,
                           BOOL udp, DWORD *pid, UINT32 *cfg)
{
    evaluations++;
    CHECK(get_cached_pid(src, sp, FALSE) == 0);
    *pid = 1234;
    *cfg = 1;
    return verdict;
}

static RuleAction mock_rule6(const UINT8 *src, UINT16 sp, const UINT8 *dst, UINT16 dp,
                            BOOL udp, DWORD *pid, UINT32 *cfg)
{
    evaluations++;
    *pid = 1234;
    *cfg = 1;
    return verdict;
}

static void reset_state(void)
{
    remove_connection(test_port, FALSE, FALSE);
    remove_connection(test_port, FALSE, TRUE);
    clear_pid_cache();
    port_clear(test_port);
    g_has_active_rules = TRUE;
    g_connection_callback = NULL;
}

static void packet(BOOL v6, BOOL syn, BOOL ack, BOOL fin, BOOL rst)
{
    memset(input, 0, sizeof(input));
    WINDIVERT_TCPHDR *tcp;
    if (v6) {
        WINDIVERT_IPV6HDR *ip = (WINDIVERT_IPV6HDR *)input;
        ip->Version = 6;
        ip->Length = htons(sizeof(*tcp));
        ip->NextHdr = IPPROTO_TCP;
        ip->HopLimit = 64;
        inet_pton(AF_INET6, "2001:db8::1", ip->SrcAddr);
        inet_pton(AF_INET6, "2001:db8::2", ip->DstAddr);
        tcp = (WINDIVERT_TCPHDR *)(input + sizeof(*ip));
        input_len = sizeof(*ip) + sizeof(*tcp);
    } else {
        WINDIVERT_IPHDR *ip = (WINDIVERT_IPHDR *)input;
        ip->Version = 4;
        ip->HdrLength = 5;
        ip->Length = htons(sizeof(*ip) + sizeof(*tcp));
        ip->Protocol = IPPROTO_TCP;
        ip->TTL = 64;
        ip->SrcAddr = inet_addr("192.0.2.1");
        ip->DstAddr = inet_addr("198.51.100.2");
        tcp = (WINDIVERT_TCPHDR *)(input + sizeof(*ip));
        input_len = sizeof(*ip) + sizeof(*tcp);
    }
    tcp->HdrLength = 5;
    tcp->SrcPort = htons(test_port);
    tcp->DstPort = htons(443);
    tcp->Syn = syn;
    tcp->Ack = ack;
    tcp->Fin = fin;
    tcp->Rst = rst;
    receives = sends = evaluations = 0;
    output_len = 0;
    running = TRUE;
    packet_processor(NULL);
}

static UINT16 sent_destination(BOOL v6)
{
    size_t offset = v6 ? sizeof(WINDIVERT_IPV6HDR) : sizeof(WINDIVERT_IPHDR);
    CHECK(output_len >= offset + sizeof(WINDIVERT_TCPHDR));
    return ntohs(((WINDIVERT_TCPHDR *)(output + offset))->DstPort);
}

int main(void)
{
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    for (int v6 = 0; v6 <= 1; v6++) {
        printf("Testing IPv%d\n", v6 ? 6 : 4);
        // Simulate a prior owner that disappeared without an observed FIN/RST.
        reset_state();
        port_set_direct(test_port);
        if (!v6) cache_pid(inet_addr("192.0.2.1"), test_port, 999, FALSE);
        verdict = RULE_ACTION_PROXY;
        packet(v6, TRUE, FALSE, FALSE, FALSE);
        CHECK(evaluations == 1);
        CHECK(sends == 1);
        CHECK(sent_destination(v6) == g_local_relay_port);
        CHECK(!port_is_direct(test_port));
        // Retransmission must still reach the relay, preserving tracked state.
        packet(v6, TRUE, FALSE, FALSE, FALSE);
        CHECK(sends == 1);
        CHECK(sent_destination(v6) == g_local_relay_port);
        packet(v6, FALSE, TRUE, FALSE, FALSE);
        CHECK(evaluations == 0);
        CHECK(sent_destination(v6) == g_local_relay_port);

        reset_state();
        port_set_direct(test_port);
        verdict = RULE_ACTION_BLOCK;
        packet(v6, TRUE, FALSE, FALSE, FALSE);
        CHECK(evaluations == 1);
        CHECK(sends == 0);

        reset_state();
        verdict = RULE_ACTION_DIRECT;
        packet(v6, TRUE, FALSE, FALSE, FALSE);
        CHECK(evaluations == 1);
        CHECK(sent_destination(v6) == 443);
        CHECK(port_is_direct(test_port));
        // Established DIRECT traffic (including SYN+ACK) retains the fast path.
        verdict = RULE_ACTION_BLOCK;
        packet(v6, FALSE, TRUE, FALSE, FALSE);
        CHECK(evaluations == 0);
        CHECK(sent_destination(v6) == 443);
        packet(v6, TRUE, TRUE, FALSE, FALSE);
        CHECK(evaluations == 0);
        CHECK(sent_destination(v6) == 443);
        for (int rst = 0; rst <= 1; rst++) {
            port_set_direct(test_port);
            packet(v6, FALSE, TRUE, !rst, rst);
            CHECK(evaluations == 0);
            CHECK(sends == 1);
            CHECK(!port_is_decided(test_port));
            CHECK(!port_is_direct(test_port));
        }
        // The bitmaps are shared: a DIRECT decision in the other family must
        // not let this family's new connection bypass BLOCK.
        reset_state();
        verdict = RULE_ACTION_DIRECT;
        packet(!v6, TRUE, FALSE, FALSE, FALSE);
        verdict = RULE_ACTION_BLOCK;
        packet(v6, TRUE, FALSE, FALSE, FALSE);
        CHECK(evaluations == 1);
        CHECK(sends == 0);
    }
    reset_state();
    WSACleanup();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
