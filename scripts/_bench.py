import os, time
from mcrcon import MCRcon
pw = os.environ['RCON_PW']

t0 = time.perf_counter()
for _ in range(5):
    with MCRcon('127.0.0.1', pw, port=27015) as m:
        m.command('/sc rcon.print("pong")')
dt = time.perf_counter() - t0
print(f"5x fresh-connect: {dt*1000:.1f} ms  avg={dt/5*1000:.1f} ms")

t0 = time.perf_counter()
m = MCRcon('127.0.0.1', pw, port=27015); m.connect()
for _ in range(5):
    m.command('/sc rcon.print("pong")')
m.disconnect()
dt = time.perf_counter() - t0
print(f"5x persistent:    {dt*1000:.1f} ms  avg={dt/5*1000:.1f} ms")

m = MCRcon('127.0.0.1', pw, port=27015); m.connect()
t0 = time.perf_counter()
last = ""
for _ in range(5):
    last = m.command('/sc rcon.print(remote.call("npc","observe","Botty",16))')
dt = time.perf_counter() - t0
m.disconnect()
print(f"5x npc_observe:   {dt*1000:.1f} ms  avg={dt/5*1000:.1f} ms  bytes/resp={len(last)}")

# also try drain_events / status which are tiny
m = MCRcon('127.0.0.1', pw, port=27015); m.connect()
t0 = time.perf_counter()
for _ in range(10):
    m.command('/sc rcon.print(remote.call("npc","status","Botty"))')
dt = time.perf_counter() - t0
m.disconnect()
print(f"10x npc_status:   {dt*1000:.1f} ms  avg={dt/10*1000:.1f} ms")
