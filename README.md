# Experiment Execution Instructions

This document explains how to run the **Google Quiche** and **Picoquic** handshake-flooding experiments for:

- **Without Address Validation**
- **With Address Validation using Retry** — Picoquic only

Replace `[IP of server]` and other placeholders with the appropriate values for the experimental machines.

---

## 1. Server Buffer

For the experiments, the server buffer was increased to:

```text
16,777,216 bytes (16 MiB)
```

Keep the same buffer configuration when reproducing the experiments.

---

## 2. Google Quiche

Google Quiche was tested only **without address validation**, because Retry was not used in the Quiche implementation.

**Server port:** `6121`

Only one server Bash script is required:

```text
run_quiche_pinned_monitor.sh
```

### 2.1 Build Quiche

If the code has been modified, rebuild before running the experiment:

```bash
cd ~/quiche

bazel build -c opt \
    quiche:quic_client \
    quiche:quic_server \
    --override_module=boringssl="$HOME/boringssl_patched" \
    --override_repository=+_repo_rules+com_google_googleurl="$HOME/googleurl_patched"
```

If no code has changed since the previous build, this step can be skipped.

### 2.2 Start the Quiche Server

On the **server machine**:

```bash
chmod +x run_quiche_pinned_monitor.sh
./run_quiche_pinned_monitor.sh
```

The script starts the Quiche server on UDP port `6121` and records server-side CPU, memory, and network measurements.

### 2.3 Configure the Quiche Client

On the **client machine**, add the following rule before starting the experiment:

```bash
sudo iptables -I INPUT 1 -p udp -s [IP of server] --sport 6121 -j DROP
```

Verify the rule:

```bash
sudo iptables -L INPUT -n -v --line-numbers | head -n 20
```

Make sure a DROP rule for UDP traffic from `[IP of server]` with source port `6121` is present.

### 2.4 Run the Quiche Client

Make sure `client_sweep_time.sh` contains the correct `[IP of server]`.

Then run:

```bash
chmod +x client_sweep_time.sh
./client_sweep_time.sh
```

The script performs the configured request-rate sweep and records the client-side measurements.

---

## 3. Picoquic — Without Address Validation

**Server port:** `4443`

For this experiment:

- Retry is disabled.
- The client drops responses received from the server.
- The server is run with `-B 16777216`.

### 3.1 Build Picoquic

If the source code was modified, build the client and server in their respective source directories:

```bash
cd [Picoquic source directory]

cmake -DPICOQUIC_FETCH_PTLS=Y .
make -j"$(nproc)"
```

Skip this step if the required binaries are already built and no code has changed.

### 3.2 Start the Picoquic Server

The server command for this experiment is:

```bash
picoquicdemo -p 4443 -B 16777216
```

When using the monitoring script:

```bash
chmod +x run_picoquic_pinned_monitor_without_address_validation.sh
./run_picoquic_pinned_monitor_without_address_validation.sh
```

Make sure the server command inside the script contains `-B 16777216` and does **not** contain `-r`.

### 3.3 Configure the Picoquic Client

On the **client machine**, add the DROP rule:

```bash
sudo iptables -I INPUT 1 -p udp -s [IP of server] --sport 4443 -j DROP
```

Verify it:

```bash
sudo iptables -L INPUT -n -v --line-numbers | head -n 20
```

A DROP rule for UDP traffic from `[IP of server]` with source port `4443` should be present.

### 3.4 Run the Picoquic Client

Make sure the client Bash script contains the correct `[IP of server]`.

Then run:

```bash
chmod +x [Picoquic client bash script]
./[Picoquic client bash script]
```

Allow the complete request-rate sweep to finish.

---

## 4. Picoquic — With Address Validation

For this experiment, Picoquic Retry is enabled.

Compared with the previous experiment:

- Remove the client-side `iptables` DROP rule.
- Enable Retry using `-r`.

### 4.1 Remove the Client DROP Rule

On the **client machine**:

```bash
sudo iptables -D INPUT -p udp -s [IP of server] --sport 4443 -j DROP
```

Verify that the rule has been removed:

```bash
sudo iptables -L INPUT -n -v --line-numbers | head -n 20
```

There should be no DROP rule for UDP packets from `[IP of server]` on source port `4443`.

The rule must be removed because the client needs to receive the Retry packet from the server.

### 4.2 Start the Picoquic Server with Retry

The server command for this experiment is:

```bash
picoquicdemo -p 4443 -r
```

If using the server monitoring Bash script, make sure its Picoquic command:

- contains `-r`;

Then start the script:

```bash
./run_picoquic_pinned_monitor_with_address_validation.sh
```

### 4.3 Run the Picoquic Client

After confirming that the DROP rule has been removed and the Retry-enabled server is running:

```bash
./[Picoquic client bash script]
```

The client can now receive the server's Retry packet and continue the Retry-based address-validation exchange.

---

## 5. Experiment Configuration

| Experiment | Client Configuration | Server Configuration |
| --- | --- | --- |
| **Quiche — Without Address Validation** | DROP UDP from `[IP of server]:6121` | `run_quiche_pinned_monitor.sh` |
| **Picoquic — Without Address Validation** | DROP UDP from `[IP of server]:4443` | `picoquicdemo -p 4443 -B 16777216` |
| **Picoquic — With Address Validation** | Remove DROP rule | `picoquicdemo -p 4443 -r` |

---

## 6. Execution Order

For each experiment, follow this order:

1. Build the client and server if the source code has changed.
2. Configure the server for the required experiment.
3. Start the server monitoring Bash script.
4. Add or remove the client `iptables` rule as required.
5. Verify the `iptables` configuration.
6. Run the corresponding client Bash script.
7. Allow the complete request-rate sweep to finish.
8. Save the generated client and server measurement files.
