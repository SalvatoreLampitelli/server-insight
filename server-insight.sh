#!/bin/bash

# server-insight.sh
# A comprehensive script to provide system insights for NUMA, CPU, and PCI affinity,
# along with configuration-aware tips for optimizing multi-socket and multi-core Linux servers.

# --- Configuration & Styling ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Global variable for tips ---
SHOW_TIPS=false

# --- Function to display tips conditionally ---
print_tip() {
    if $SHOW_TIPS; then
        echo -e "${YELLOW}Tip:${NC} $1"
    fi
}

# --- Check for necessary commands ---
check_commands() {
    local missing_cmds=()
    for cmd in lscpu numactl lspci lshw cpupower chrt swapon; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo -e "${RED}Error: The following commands are missing. Please install them:${NC}"
        echo -e "${YELLOW}  - ${missing_cmds[*]}${NC}"
        echo -e "${YELLOW}  On Fedora, you might need: sudo dnf install util-linux numactl pciutils hwinfo kernel-tools${NC}"
        exit 1
    fi
}

# --- Section 1: System Overview and Kernel Configuration ---
print_system_overview_advanced() {
    echo -e "${BLUE}--- System Overview & Kernel Configuration ---${NC}"
    echo -e "${GREEN}Hostname:${NC} $(hostname)"
    echo -e "${GREEN}Kernel Version:${NC} $(uname -r)"
    echo -e "${GREEN}OS:${NC} $(cat /etc/fedora-release 2>/dev/null || cat /etc/os-release | grep -E '^PRETTY_NAME=' | cut -d'=' -f2 | tr -d '"')"
    echo ""

    echo -e "${BLUE}--- CPU Architecture Details (lscpu) ---${NC}"
    lscpu | grep -E 'Architecture|CPU op-mode|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|Model name|NUMA node\(s\)|NUMA node[0-9] CPU\(s\)'
    echo ""
    if [ "$(lscpu | grep "Thread(s) per core" | awk '{print $NF}')" -gt 1 ] && $SHOW_TIPS; then
        echo -e "${YELLOW}Tip:${NC} Simultaneous Multithreading (SMT) is enabled. Each physical core acts as two logical cores. For maximum performance predictability in highly sensitive workloads (e.g., real-time), consider disabling SMT in BIOS/UEFI to eliminate resource contention within a physical core. For general throughput, SMT is usually beneficial."
    fi
    echo ""

    echo -e "${BLUE}--- Kernel Parameters (cmdline) ---${NC}"
    CMDLINE=$(cat /proc/cmdline)
    echo "Current Kernel Cmdline: ${CMDLINE}"
    if $SHOW_TIPS; then
        if ! echo "${CMDLINE}" | grep -q "isolcpus"; then
            echo -e "${YELLOW}Tip:${NC} For dedicated, jitter-free cores (e.g., for critical applications), consider using 'isolcpus=<CPU_LIST>' in kernel cmdline to prevent the kernel scheduler from using those CPUs for other tasks. Example: 'isolcpus=4-7,12-15'."
            echo -e "${YELLOW}Tip:${NC} If using 'isolcpus', you might also want 'nohz_full=<CPU_LIST>' and 'rcu_nocbs=<CPU_LIST>' to further reduce kernel activity on those cores."
        fi
    fi
    echo ""

    echo -e "${BLUE}--- Kernel Preemption Model ---${NC}"
    PREEMPT_MODEL="Unknown"
    if gunzip -c /proc/config.gz 2>/dev/null | grep -q "CONFIG_PREEMPT_RT=y"; then
        PREEMPT_MODEL="Real-time (PREEMPT_RT)"
    elif grep -q "CONFIG_PREEMPT_VOLUNTARY=y" /boot/config-$(uname -r) 2>/dev/null; then
        PREEMPT_MODEL="Voluntary Preemption"
    elif grep -q "CONFIG_PREEMPT_NONE=y" /boot/config-$(uname -r) 2>/dev/null; then
        PREEMPT_MODEL="No Preemption (Desktop/Server Default)"
    fi
    echo "Preemption Model: ${PREEMPT_MODEL}"
    if $SHOW_TIPS; then
        if [[ "$PREEMPT_MODEL" != "Real-time (PREEMPT_RT)" ]]; then
            echo -e "${YELLOW}Tip:${NC} For applications requiring strict timing guarantees (e.g., industrial control, audio processing), a fully preemptible kernel (PREEMPT_RT) is highly recommended to minimize scheduler latencies. This usually requires installing a specific kernel package."
        fi
    fi
    echo ""

    echo -e "${BLUE}--- TSC (Timestamp Counter) Stability ---${NC}"
    if grep -q "constant_tsc" /proc/cpuinfo && grep -q "nonstop_tsc" /proc/cpuinfo; then
        echo "  TSC is constant and non-stop (good for high-resolution timing)."
    else
        echo "  TSC may not be constant or non-stop. Check 'constant_tsc' and 'nonstop_tsc' flags in /proc/cpuinfo. For accurate timing, ensure this is enabled in BIOS if possible."
    fi
    echo ""

    echo -e "${BLUE}--- NMI Watchdog Status ---${NC}"
    if [ -f /proc/sys/kernel/nmi_watchdog ]; then
        NMI_WATCHDOG_STATUS=$(cat /proc/sys/kernel/nmi_watchdog)
        echo "  nmi_watchdog: ${NMI_WATCHDOG_STATUS}"
        if [ "$NMI_WATCHDOG_STATUS" -eq "1" ] && $SHOW_TIPS; then
            echo -e "${YELLOW}Tip:${NC} NMI watchdog helps detect hung CPUs but can introduce very minor jitter. For ultra-low latency, it's sometimes disabled (kernel param: nmi_watchdog=0), but use with caution as it can hide severe system issues."
        fi
    else
        echo "  nmi_watchdog status not available."
    fi
    echo ""
}

# --- Section 2: NUMA Topology ---
print_numa_topology_advanced() {
    echo -e "${BLUE}--- NUMA Topology (numactl --hardware) ---${NC}"
    numactl --hardware
    echo ""
    print_tip " 'node distances' shows the relative cost of accessing memory between NUMA nodes. Lower numbers mean faster access. '10' is typically local access, '20' or '30+' indicates remote access across sockets. This is fundamental for optimizing memory access patterns."
    print_tip " Each 'node X cpus:' lists the logical CPU IDs belonging to that NUMA node. This is crucial for process affinity."
    echo ""
}

# --- Section 3: PCI Device NUMA Affinity ---
print_pci_numa_affinity_advanced() {
    echo -e "${BLUE}--- PCI Device NUMA Affinity (Network Adapters) ---${NC}"
    print_tip "This section focuses on network adapters due to their common need for NUMA optimization."
    echo ""

    network_devices=$(lshw -c network -businfo 2>/dev/null | awk '/network/{print $1}')
    if [ -z "$network_devices" ]; then
        echo -e "${RED}No network devices found with lshw.${NC}"
        echo ""
        return
    fi

    ALL_NICS_ON_NODE0=true
    FIRST_NUMA_NODE=""
    for dev_bus_id in $network_devices; do
        pci_id=$(echo "$dev_bus_id" | sed 's/^pci@0000:\(.*\)/\1/')
        interface_name=$(lshw -c network -businfo 2>/dev/null | grep "$dev_bus_id" | awk '{print $2}')

        echo -e "${GREEN}Device: ${interface_name} (${pci_id})${NC}"
        numa_node_sysfs=$(cat "/sys/class/net/$interface_name/device/numa_node" 2>/dev/null)
        lspci_output=$(lspci -vvs "$pci_id" 2>/dev/null)
        numa_node_lspci=$(echo "$lspci_output" | grep "NUMA node:" | awk '{print $NF}')

        DEVICE_NUMA_NODE=""
        if [ -n "$numa_node_sysfs" ]; then
            DEVICE_NUMA_NODE="$numa_node_sysfs"
            echo -e "  - Determined NUMA Node: ${numa_node_sysfs} (from /sys/class/net/.../device/numa_node)"
            if [ "$numa_node_sysfs" -eq "-1" ]; then
                echo -e "${YELLOW}    (Value -1 means no specific NUMA affinity reported, kernel will try to optimize.)"
            fi
        elif [ -n "$numa_node_lspci" ]; then
             DEVICE_NUMA_NODE="$numa_node_lspci"
             echo -e "  - Determined NUMA Node: ${numa_node_lspci} (from lspci)"
        else
            echo "  - Could not determine NUMA node for this device."
        fi

        if [ -n "$DEVICE_NUMA_NODE" ] && [ "$DEVICE_NUMA_NODE" -ne "-1" ]; then
            if [ -z "$FIRST_NUMA_NODE" ]; then
                FIRST_NUMA_NODE="$DEVICE_NUMA_NODE"
            elif [ "$DEVICE_NUMA_NODE" -ne "$FIRST_NUMA_NODE" ]; then
                ALL_NICS_ON_NODE0=false # Set to false if any NIC is on a different node
            fi
        fi
        echo ""
    done
    if $SHOW_TIPS; then
        if [ "$ALL_NICS_ON_NODE0" == "true" ] && [ "$FIRST_NUMA_NODE" -eq "0" ]; then
            echo -e "${YELLOW}Tip:${NC} All detected network interfaces appear to be affiliated with NUMA Node 0. For optimal network performance, prioritize running network-intensive processes (and their memory) on cores within NUMA Node 0."
            echo -e "${YELLOW}Tip:${NC} Consider reserving NUMA Node 1 for compute-intensive workloads that primarily use local memory and don't need low-latency network access."
        else
            echo -e "${YELLOW}Tip:${NC} Network interfaces are distributed across NUMA nodes. For optimal performance, ensure network-intensive processes (and their memory) are pinned to cores on the *same* NUMA node as the NIC they primarily use."
        fi
    fi
    echo ""
}

# --- Section 4: CPU Power Management (C-States & P-States) ---
print_cpu_power_management_advanced() {
    echo -e "${BLUE}--- CPU Power Management (C-States & P-States) ---${NC}"
    echo -e "${GREEN}CPU Governors:${NC}"
    GOVERNORS_SET=true
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        governor_path="$cpu/cpufreq/scaling_governor"
        if [ -f "$governor_path" ]; then
            current_governor=$(cat "$governor_path")
            echo "  $(basename $cpu): ${current_governor}"
            if [[ "$current_governor" != "performance" ]]; then
                GOVERNORS_SET=false
            fi
        fi
    done
    echo ""
    if $SHOW_TIPS && ! $GOVERNORS_SET; then
        echo -e "${YELLOW}Tip:${NC} Not all CPU governors are set to 'performance'. For maximum consistent performance, ensure all CPU governors are set to 'performance' to prevent frequency scaling and associated latency. To set: 'sudo cpupower frequency-set -g performance' or use 'tuned-adm profile throughput-performance' (or 'latency-performance')."
    elif $SHOW_TIPS; then
        echo -e "${YELLOW}Tip:${NC} All CPU governors are set to 'performance', which is optimal for consistent high performance."
    fi
    echo ""

    echo -e "${GREEN}CPU C-States:${NC}"
    if command -v cpupower &> /dev/null; then
        C_STATES_INFO=$(cpupower idle-info)
        echo "${C_STATES_INFO}"
        if echo "${C_STATES_INFO}" | grep -q "C3" || echo "${C_STATES_INFO}" | grep -q "C6" || echo "${C_STATES_INFO}" | grep -q "C7"; then
            if $SHOW_TIPS; then
                echo -e "${YELLOW}Tip:${NC} Deeper C-states (C3, C6, C7, etc.) are enabled. These save power but introduce latency when the CPU has to wake up. For extreme low-latency or real-time applications, consider disabling deeper C-states in BIOS/UEFI. Only C0 (active) and C1 (halt) should ideally be allowed."
            fi
        elif $SHOW_TIPS; then
            echo -e "${YELLOW}Tip:${NC} Deeper C-states appear to be disabled or not in use, which is good for minimizing latency and maximizing responsiveness."
        fi
    else
        echo "  'cpupower' not found. Cannot display C-States info."
    fi
    echo ""
}

# --- Section 5: Memory & I/O Tuning ---
print_mem_io_tuning_advanced() {
    echo -e "${BLUE}--- Memory & I/O Tuning ---${NC}"

    echo -e "${GREEN}Swap Status (Swappiness):${NC}"
    SWAPPINESS_VALUE=$(cat /proc/sys/vm/swappiness)
    echo "  vm.swappiness = ${SWAPPINESS_VALUE}"
    SWAP_USAGE=$(swapon --show=USED --noheadings 2>/dev/null | awk '{print $1}')
    if [ -n "$SWAP_USAGE" ]; then
        echo "  Current swap usage: ${SWAP_USAGE}"
    else
        echo "  No swap usage detected."
    fi
    if $SHOW_TIPS; then
        if [ "$SWAPPINESS_VALUE" -gt "10" ]; then
            echo -e "${YELLOW}Tip:${NC} vm.swappiness is currently ${SWAPPINESS_VALUE}. For performance-critical applications, set to a lower value (e.g., 10 or 0) to minimize swapping to disk, which introduces significant latency. Persistent setting via /etc/sysctl.conf (e.g., 'vm.swappiness=10')."
        elif [ "$SWAPPINESS_VALUE" -gt "0" ]; then
            echo -e "${YELLOW}Tip:${NC} vm.swappiness is set low (${SWAPPINESS_VALUE}), which is good for performance by reducing disk swapping. For absolute zero swap, set to 0 and ensure no swap partitions/files are configured."
        fi
        if [ -n "$SWAP_USAGE" ] && [ "$SWAP_USAGE" != "0B" ] && [ "$SWAP_USAGE" != "N/A" ]; then
            echo -e "${RED}Warning:${NC} Swap is currently in use (${SWAP_USAGE}). Any disk swapping introduces significant latency and should be avoided for performance-critical or real-time applications."
        fi
    fi
    echo ""

    echo -e "${GREEN}Huge Pages Status:${NC}"
    grep -E 'AnonHugePages|HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo
    THP_STATUS=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
    echo "  Transparent Huge Pages (THP) enabled status: ${THP_STATUS}"
    if $SHOW_TIPS; then
        if [[ "$THP_STATUS" != "never" ]]; then
            echo -e "${YELLOW}Tip:${NC} Transparent Huge Pages (THP) are currently enabled. While helpful for some general workloads, THP can cause unpredictable latency spikes during page compaction. For performance-critical or real-time applications, consider disabling THP by setting it to 'never'. Persistent setting: add 'transparent_hugepage=never' to kernel cmdline."
        elif [[ "$THP_STATUS" == "never" ]]; then
             echo -e "${YELLOW}Tip:${NC} Transparent Huge Pages (THP) are disabled, which is generally good for consistent performance in critical applications."
        fi
        echo -e "${YELLOW}Tip:${NC} Explicit Huge Pages (pre-allocated, e.g., 2MB or 1GB) can improve performance for applications with very large, contiguous memory footprints by reducing TLB misses. Requires application support or specific configuration."
    fi
    echo ""

    echo -e "${GREEN}I/O Schedulers:${NC}"
    for device in /sys/block/*; do
        if [ -d "$device/queue" ]; then
            scheduler_path="$device/queue/scheduler"
            if [ -f "$scheduler_path" ]; then
                current_scheduler=$(cat "$scheduler_path")
                echo "  $(basename $device): $current_scheduler"
            fi
        fi
    done
    if $SHOW_TIPS; then
        echo -e "${YELLOW}Tip:${NC} For NVMe/SSDs, 'none' or 'noop' is generally best (no mechanical seek time), as these schedulers provide minimal intervention. For traditional HDDs, 'mq-deadline' or 'bfq' might be preferred depending on workload. To set (e.g., for NVMe/SSD): 'echo noop | sudo tee /sys/block/<device_name>/queue/scheduler' (persistent via udev rules)."
    fi
    echo ""

    echo -e "${BLUE}--- Network (IRQ & RSS) Tuning ---${NC}"
    IRQBALANCE_STATUS=$(systemctl is-active irqbalance 2>/dev/null)
    if [ "$IRQBALANCE_STATUS" == "active" ]; then
        echo "  irqbalance status: ${IRQBALANCE_STATUS}"
        if $SHOW_TIPS; then
            echo -e "${YELLOW}Tip:${NC} 'irqbalance' is active. While good for general load balancing, for very high-performance or low-latency network applications, it's often recommended to DISABLE irqbalance and manually set IRQ affinities to specific CPUs."
            echo -e "${YELLOW}Tip:${NC} To disable: 'sudo systemctl stop irqbalance && sudo systemctl disable irqbalance'."
        fi
    else
        echo "  irqbalance status: ${IRQBALANCE_STATUS} (or not installed/running)"
        if $SHOW_TIPS; then
            echo -e "${YELLOW}Tip:${NC} 'irqbalance' is not active. This is often desired for manual IRQ affinity management in high-performance scenarios."
        fi
    fi
    echo ""
    if $SHOW_TIPS; then
        echo -e "${YELLOW}Tip:${NC} For critical network performance, manually assign IRQs for your NICs to specific CPUs. Check IRQs: 'cat /proc/interrupts'. Set affinity (example for IRQ 123 to CPU 0): 'echo 1 > /proc/irq/123/smp_affinity_list'."
        echo -e "${YELLOW}Tip:${NC} If your NIC supports Receive Side Scaling (RSS), configure its queues and assign them to different CPUs within the same NUMA node for parallel network processing. Check queues: 'ethtool -l <interface_name>'. Adjust channels: 'sudo ethtool -L <interface_name> combined <N>'."
    fi
    echo ""
}

# --- Section 6: Practical Usage & General Optimization Tips ---
print_usage_tips_conditional() {
    echo -e "${BLUE}--- Practical Usage & General Optimization Tips ---${NC}"
    echo -e "Your system has ${GREEN}$(lscpu | grep "Socket(s)" | awk '{print $NF}') physical sockets${NC} and ${GREEN}$(lscpu | grep "NUMA node(s)" | awk '{print $NF}') NUMA nodes${NC}."
    echo -e "Total Logical CPUs: ${GREEN}$(lscpu | grep "CPU(s):" | head -n 1 | awk '{print $NF}')${NC}"
    echo ""

    echo -e "${BLUE}1. Understanding Your NUMA Nodes:${NC}"
    numa_node_0_cpus=$(numactl --hardware | grep "node 0 cpus:" | cut -d':' -f2 | xargs)
    numa_node_1_cpus=$(numactl --hardware | grep "node 1 cpus:" | cut -d':' -f2 | xargs)
    echo -e "   - ${GREEN}NUMA Node 0 (Socket 0 assumed):${NC} CPUs ${numa_node_0_cpus}"
    echo -e "   - ${GREEN}NUMA Node 1 (Socket 1 assumed):${NC} CPUs ${numa_node_1_cpus}"
    echo ""
    echo -e "${YELLOW}Tip:${NC} These CPU lists are critical for defining process affinity to ensure workloads access local memory and resources. Optimize by keeping processes and their data on the same NUMA node to maximize local memory access and reduce inter-socket communication (NUMA penalty)."

    echo -e "${BLUE}2. How to Instance Processes with NUMA Affinity:${NC}"
    echo -e "   Use the '${GREEN}numactl${NC}' command prefix."
    echo -e "   Syntax: ${GREEN}numactl --cpunodebind=<node_id> --membind=<node_id> [optional: taskset -c <cpu_list>] <your_program> [args]${NC}"
    echo ""
    echo -e "   ${GREEN}Example 1: Run a compute-intensive app on NUMA Node 1:${NC}"
    echo -e "     (Assumes 'compute_app' is not network-bound)"
    echo -e "     ${YELLOW}numactl --cpunodebind=1 --membind=1 /path/to/compute_app${NC}"
    echo -e "     ${NC}This dedicates 'compute_app' to the second socket's CPUs and local memory."
    echo ""
    echo -e "   ${GREEN}Example 2: Run a network-intensive app on NUMA Node 0:${NC}"
    echo -e "     (Based on script's findings, all NICs are likely on NUMA Node 0)"
    echo -e "     ${YELLOW}numactl --cpunodebind=0 --membind=0 /path/to/network_app${NC}"
    echo -e "     ${NC}This ensures 'network_app' processes data locally to its network interfaces."
    echo ""
    echo -e "   ${GREEN}Example 3: Pin a specific thread/process to a single logical CPU (e.g., CPU 0 on Node 0):${NC}"
    echo -e "     ${YELLOW}numactl --cpunodebind=0 --membind=0 taskset -c 0 /path/to/single_threaded_app${NC}"
    echo -e "     ${NC}Useful for ultra-low latency or debugging, but may limit throughput if not optimized."
    echo ""
    echo -e "${BLUE}3. Managing Running Processes:${NC}"
    echo -e "   - Find a process PID: ${YELLOW}ps aux | grep <process_name>${NC}"
    echo -e "   - Modify CPU affinity of running process: ${YELLOW}taskset -pc <cpu_list> <PID>${NC}"
    echo -e "   - Modify NUMA affinity of running process (may not reallocate existing memory): ${YELLOW}numactl --cpunodebind=<node_id> --membind=<node_id> --pid <PID>${NC}"
    echo ""
    echo -e "${BLUE}4. Real-time Scheduling Policies (Advanced):${NC}"
    echo -e "   For applications requiring strict timing guarantees, consider real-time scheduling policies like SCHED_FIFO or SCHED_RR."
    echo -e "   ${YELLOW}Example (SCHED_FIFO with priority 90):${NC} ${GREEN}sudo chrt -f 90 /path/to/your_rt_app${NC}"
    echo -e "   ${RED}WARNING:${NC} Real-time priorities (1-99) can easily make your system unstable if misused. High-priority RT tasks can starve other processes, including system daemons. Test thoroughly!"
    echo ""
    echo -e "${BLUE}5. System Management Interrupts (SMIs):${NC}"
    echo -e "${YELLOW}Tip:${NC} SMIs are non-maskable hardware interrupts handled by firmware. They can cause unpredictable latency spikes. Debugging SMIs is complex and often requires vendor-specific tools or BIOS settings (e.g., disable 'C-state reporting', 'DRAM scrub')."
    echo ""
    echo -e "${BLUE}--- End of Insight Report ---${NC}"
}

# --- Main Script Execution ---

# Check for --tips argument
if [[ "$1" == "--tips" ]]; then
    SHOW_TIPS=true
fi

check_commands
print_system_overview_advanced
print_numa_topology_advanced
print_pci_numa_affinity_advanced
print_cpu_power_management_advanced
print_mem_io_tuning_advanced
if $SHOW_TIPS; then
    print_usage_tips_conditional
fi

echo -e "${BLUE}--- Analysis Complete ---${NC}"
if ! $SHOW_TIPS; then
    echo -e "Run with ${YELLOW}./server-insight.sh --tips${NC} for detailed optimization guidance and examples, based on your current configuration."
fi
