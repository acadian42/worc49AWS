# Sizing

How node density, heap, and capacity are chosen for **125 GiB** physical hosts.
The platform derives all of this at run time from each host's real RAM; the
tables below show the values for the reference host so the trade-offs are
explicit.

> **Tested vs assumed.** Values that fall directly out of the variable contract
> arithmetic are **facts** (deterministic). The default density (**N=3**), the
> per-day PCAP/SPI volumes, and retention are **assumptions / placeholders** that
> must be confirmed by a benchmark and the capacity worksheet for your traffic.

## Reference host inputs (facts, from the variable contract)

| Variable                   | Value     | Source                              |
|----------------------------|-----------|-------------------------------------|
| Host RAM                   | 125 GiB   | reference hardware                  |
| `os_docker_reserve_gib`    | 13 GiB    | `group_vars/...elasticsearch...yml` |
| Usable for ES              | 112 GiB   | `125 - 13`                          |
| `es_heap_fraction`         | 0.5       | heap = 50% of container limit       |
| `es_heap_max_gib`          | 26 GiB    | compressed-oops ceiling             |

## Density tables (N = nodes per host)

Per-container limit `= floor(usable / N)`. Heap `= min(floor(limit × 0.5), 26)`,
min 1 GiB. FS cache ≈ container limit − heap (page cache the OS uses for Lucene).

### N = 3 (current production default)

| Metric                       | Value                  |
|------------------------------|------------------------|
| Container memory limit       | **37 GiB** (`112/3`)   |
| JVM heap per node            | **18 GiB**             |
| FS cache per node (≈)        | **19 GiB**             |
| Aggregate heap per host      | **54 GiB** (`3×18`)    |
| Aggregate heap, 5 hosts (15 nodes) | **270 GiB**      |

### N = 4

| Metric                       | Value                  |
|------------------------------|------------------------|
| Container memory limit       | **28 GiB** (`112/4`)   |
| JVM heap per node            | **14 GiB**             |
| FS cache per node (≈)        | **14 GiB**             |
| Aggregate heap per host      | **56 GiB** (`4×14`)    |
| Aggregate heap, 5 hosts (20 nodes) | **280 GiB**      |

### N = 5

| Metric                       | Value                  |
|------------------------------|------------------------|
| Container memory limit       | **22 GiB** (`112/5`)   |
| JVM heap per node            | **11 GiB**             |
| FS cache per node (≈)        | **11 GiB**             |
| Aggregate heap per host      | **55 GiB** (`5×11`)    |
| Aggregate heap, 5 hosts (25 nodes) | **275 GiB**      |

### Trade-offs

* **More nodes (higher N) → more shards/parallelism and more aggregate heap**,
  but **smaller heap and smaller FS cache per node**. Below ~half the limit for
  page cache, large PCAP/SPI scans go to disk more often.
* **Stay under the 26 GiB compressed-oops ceiling.** All three N options already
  do; never size a single heap above ~26 GiB or you lose compressed pointers.
* **N=3 is the default** because it keeps a healthy FS cache (19 GiB) and 18 GiB
  heaps while still giving 15 data-bearing nodes across 5 failure domains.
* Aggregate heap is nearly flat across N (270–280 GiB) — density mostly trades
  *per-node* cache for *shard count*, not total memory. **Pick N from the
  benchmark** (see rule below), not from a desire for more containers.

## Selecting the production default N from the benchmark

1. Run the same ingest + representative analyst query workload at N=3, 4, 5.
2. Record sustained capture pps/drops, indexing rate, p95 query latency, and GC
   pause time per node.
3. **Choose the largest N that keeps p95 query latency and GC within target AND
   shows zero capture drops** — i.e. the smallest per-node cache that the query
   mix tolerates. If results tie, prefer the **lower N** (bigger cache, fewer
   shards to manage). The shipped default is **N=3** until a benchmark says
   otherwise; change it via `elasticsearch_nodes_per_host`.

## Capacity worksheet

Inputs to measure (do **not** guess these — they drive everything downstream):

| Symbol         | Meaning                                    | How to get it          |
|----------------|--------------------------------------------|------------------------|
| `Gbps`         | sustained capture throughput               | measured at the NIC    |
| `dup`          | de-dup / filtered fraction kept (0–1)      | BPF + dedup measured   |
| `R_pcap`       | PCAP retention (days)                      | `arkime_pcap_retention_days` (7) |
| `R_spi`        | SPI/session retention (days)               | `es_spi_retention_days` (30)     |
| `B`            | avg bytes of SPI metadata per session      | measured from a sample |
| `S_day`        | sessions/day                               | measured from a sample |
| `repl`         | ES replica count + 1 (copies on disk)      | `es_index_replicas + 1` = 2 |

### PCAP storage (per recorder)

```text
bytes/day   = Gbps × 1e9 / 8 × 86400 × dup
PCAP_total  = bytes/day × R_pcap          # on the recorder's local disk
```

`arkime_free_space` (10%) and `arkime_max_file_size_g` (12) cap how full the
PCAP filesystem gets; Arkime deletes oldest PCAP first when the watermark hits.

### SPI / Elasticsearch storage (cluster-wide)

```text
SPI_raw/day = S_day × B
SPI_disk    = SPI_raw/day × R_spi × repl   # ×2 for replica=1
per_node    = SPI_disk / (total data nodes)
```

Cross-check `per_node` against the data device size and the disk watermarks
(`low 85% / high 90% / flood 95%`). Set `es_index_shards` so each shard targets
~20–50 GB; the default `es_index_shards: 12` (~1 per data node at N=3) is a
starting point to tune from this worksheet, not a fact.
