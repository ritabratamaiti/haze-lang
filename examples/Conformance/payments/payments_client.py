"""
A payment client that retries charge requests over an unreliable network.

This is the implementation under test. Its specification is payments.hz. The network is
injected, so tests can control exactly which messages are lost.
"""
from dataclasses import dataclass, field

MAX_ATTEMPTS = 3
TIMEOUT_MS = 1000
RTT_MS = 80


class Network:
    """Decides whether each message is lost. `lost()` is called once per message."""

    def lost(self) -> bool:
        raise NotImplementedError


@dataclass
class PaymentServer:
    """Charges a card at most once per idempotency key."""

    charges: dict = field(default_factory=dict)

    def charge(self, key: str, amount: int) -> str:
        if key not in self.charges:
            self.charges[key] = amount
        return f"receipt-{key}"


@dataclass
class Result:
    status: str          # "Done" or "GaveUp"
    attempts: int
    charges: int
    acked: bool
    latency_ms: int


def pay(network: Network, server: PaymentServer, key: str, amount: int) -> Result:
    """Sends a charge request, retrying after a timeout up to MAX_ATTEMPTS times."""
    latency = 0
    attempts = 0
    while attempts < MAX_ATTEMPTS:
        attempts += 1
        if network.lost():                      # the request never reaches the server
            latency += TIMEOUT_MS
            continue
        server.charge(key, amount)
        if network.lost():                      # the response never reaches the client
            latency += TIMEOUT_MS
            continue
        latency += RTT_MS
        return Result("Done", attempts, len(server.charges), True, latency)
    return Result("GaveUp", attempts, len(server.charges), False, latency)
