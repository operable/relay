## Overview

A relatively simple protocol governs communications between Loop and one or more Relay instances.
The primary motivators for the protocol's design were authentication between Loop and Relay hosts,
easy message verification, and host failure detection and recovery. A certain degree of future
proofing is also desirable since we expect both Loop and Relay to evolve quickly and substantially in
the coming months.

### Authentication & Message Veracity

Loop uses Ed25519 keys and signatures to authenticate communications between the bot and Relay hosts.
Ed25519 was selected due to its category leading performance and apparent robustness based on a survey
of current literature.

Ed25519 keys are used during the introduction phase of discovery and to check message veracity thereafter.
[Discovery](bot_shell_protocol.html#Discovery) describes the process by which Loop and Relay verify each
other's identity. [Message Verification](bot_shell_protocol.html#Verification) describes the process of enforcing
message veracity.

### Failure Detection & Recovery

Loop and Relay hosts send brief "ping" messages at regular intervals to ensure each host is available. The 5 most
recent ping results are kept and used to decide the online, or available, status of hosts. A damping factor is applied
to the availability calculation as an anti-flap measure.

## Discovery

## Message Verification

## Liveness Detection
