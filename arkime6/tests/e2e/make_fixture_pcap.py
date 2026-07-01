#!/usr/bin/env python3
"""
Generate a small, deterministic PCAP fixture for the E2E Arkime ingestion test.
Recognizable markers used by the verification step:
  * a DNS A query for  fpc-e2e-smoke.example.test
  * an HTTP GET  http://10.99.0.80/fpc-e2e-marker  (Host: fpc-e2e.example.test)
  * fixed endpoints 10.99.0.10 <-> 10.99.0.80 and 10.99.0.10 -> 10.99.0.53
No real/untrusted traffic; everything is synthesized locally with scapy.
"""
import os
from scapy.all import Ether, IP, UDP, TCP, DNS, DNSQR, Raw, wrpcap  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "fpc-e2e-fixture.pcap")
os.makedirs(os.path.dirname(OUT), exist_ok=True)

CLIENT = "10.99.0.10"
WEB = "10.99.0.80"
DNSV = "10.99.0.53"
cmac, smac, dmac = "02:00:00:00:00:10", "02:00:00:00:00:80", "02:00:00:00:00:53"
pkts = []

# DNS query + response
pkts.append(Ether(src=cmac, dst=dmac) / IP(src=CLIENT, dst=DNSV) / UDP(sport=40000, dport=53) /
            DNS(id=0x1111, rd=1, qd=DNSQR(qname="fpc-e2e-smoke.example.test", qtype="A")))
pkts.append(Ether(src=dmac, dst=cmac) / IP(src=DNSV, dst=CLIENT) / UDP(sport=53, dport=40000) /
            DNS(id=0x1111, qr=1, aa=1, qd=DNSQR(qname="fpc-e2e-smoke.example.test", qtype="A"),
                an=None))

# TCP 3-way handshake to the web server
sp, dp = 41000, 80
pkts.append(Ether(src=cmac, dst=smac) / IP(src=CLIENT, dst=WEB) / TCP(sport=sp, dport=dp, flags="S", seq=1000))
pkts.append(Ether(src=smac, dst=cmac) / IP(src=WEB, dst=CLIENT) / TCP(sport=dp, dport=sp, flags="SA", seq=5000, ack=1001))
pkts.append(Ether(src=cmac, dst=smac) / IP(src=CLIENT, dst=WEB) / TCP(sport=sp, dport=dp, flags="A", seq=1001, ack=5001))

# HTTP GET with a recognizable URI + Host header
http_req = ("GET /fpc-e2e-marker HTTP/1.1\r\n"
            "Host: fpc-e2e.example.test\r\n"
            "User-Agent: fpc-e2e-smoke/1.0\r\n\r\n")
pkts.append(Ether(src=cmac, dst=smac) / IP(src=CLIENT, dst=WEB) /
            TCP(sport=sp, dport=dp, flags="PA", seq=1001, ack=5001) / Raw(load=http_req))
http_resp = ("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n\r\nfpc-e2e-ok!!\n")
pkts.append(Ether(src=smac, dst=cmac) / IP(src=WEB, dst=CLIENT) /
            TCP(sport=dp, dport=sp, flags="PA", seq=5001, ack=1001 + len(http_req)) / Raw(load=http_resp))
# graceful close
pkts.append(Ether(src=cmac, dst=smac) / IP(src=CLIENT, dst=WEB) / TCP(sport=sp, dport=dp, flags="FA", seq=1001 + len(http_req), ack=5001 + len(http_resp)))
pkts.append(Ether(src=smac, dst=cmac) / IP(src=WEB, dst=CLIENT) / TCP(sport=dp, dport=sp, flags="FA", seq=5001 + len(http_resp), ack=1002 + len(http_req)))

wrpcap(OUT, pkts)
print(f"wrote {len(pkts)} packets to {OUT}")
