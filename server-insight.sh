#!/bin/bash

# server-insight.sh
# A comprehensive script to provide system insights for NUMA, CPU, and PCI affinity,
# along with tips for optimizing multi-socket and multi-core Linux servers (like AMD EPYC).

# --- Configuration & Styling ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Check for necessary commands ---
check_commands() {
    local missing_cmds=()
    for cmd in lscpu numactl lspci lshw; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -gt 0 ]; then
        echo -e "${RED}Error: The following commands are missing. Please install them:${NC}"
        echo -e "${YELLOW}  - ${missing_cmds[*]}${NC}"
        echo -e "${YELLOW}  On Fedora, you might need: sudo dnf install util-linux numactl pciutils hwinfo${NC}"
        exit 1
    fi
}

# --- Section 1: System Overview ---
print_system_overview() {
    echo -e "${BLUE}--- System Overview ---${NC}"
    echo -e "${GREEN}Hostname:${NC} $(hostname)"
    echo -e "${GREEN}Kernel Version:${NC} $(uname -r)"
    echo -e "${GREEN}OS:${NC} $(cat /etc/fedora-release 2>/dev/null || cat /etc/os-release | grep -E '^PRETTY_NAME=' | cut -d'=' -f2 | tr -d '"')"
    echo ""
    echo -e "${BLUE}--- CPU Architecture Details (lscpu) ---${NC}"
    lscpu | grep -E 'Architecture|CPU op-mode|Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)|Model name|NUMA node\(s\)|NUMA node[0-9] CPU\(s\)'
    echo ""
    echo -e "${YELLOW}Tip:${NC} 'Thread(s) per core: 2' indicates Simultaneous Multithreading (SMT) is enabled. Each physical core acts as two logical cores. If performance-critical single-threaded tasks suffer from SMT overhead, consider disabling it in BIOS/UEFI."
    echo -e "${YELLOW}Tip:${NC} Note 'Core(s) per socket' and 'Socket(s)' for your physical layout. Your system has $(lscpu | grep "Core(s) per socket" | awk '{print $NF}') physical cores per of $(lscpu | grep Socket | awk '{print $NF}') sockets."
    echo ""
}

# --- Section 2: NUMA Topology ---
print_numa_topology() {
    echo -e "${BLUE}--- NUMA Topology (numactl --hardware) ---${NC}"
    numactl --hardware
    echo ""
    echo -e "${YELLOW}Tip:${NC} 'node distances' shows the relative cost of accessing memory between NUMA nodes. Lower numbers mean faster access. '10' is typically local access, '20' or '30+' indicates remote access across sockets."
    echo -e "${YELLOW}Tip:${NC} Each 'node X cpus:' lists the logical CPU IDs belonging to that NUMA node. This is crucial for process affinity."
    echo ""
}

# --- Section 3: PCI Device NUMA Affinity ---
print_pci_numa_affinity() {
    echo -e "${BLUE}--- PCI Device NUMA Affinity (Network Adapters) ---${NC}"
    echo -e "${YELLOW}Note:${NC} This section focuses on network adapters due to their common need for NUMA optimization."
    echo ""

    network_devices=$(lshw -c network -businfo 2>/dev/null | awk '/network/{print $1}')
    if [ -z "$network_devices" ]; then
        echo -e "${RED}No network devices found with lshw.${NC}"
        echo ""
        return
    fi

    for dev_bus_id in $network_devices; do
        # Extract the relevant part for lspci (e.g., 0000:01:00.0 -> 01:00.0)
        pci_id=$(echo "$dev_bus_id" | sed 's/^pci@0000:\(.*\)/\1/')
        interface_name=$(lshw -c network -businfo 2>/dev/null | grep "$dev_bus_id" | awk '{print $2}')

        echo -e "${GREEN}Device: ${interface_name} (${pci_id})${NC}"
        lspci_output=$(lspci -vvs "$pci_id" 2>/dev/null)
        numa_node_lspci=$(echo "$lspci_output" | grep "NUMA node:" | awk '{print $NF}')
        numa_node_sysfs=$(cat "/sys/class/net/$interface_name/device/numa_node" 2>/dev/null)

        if [ -n "$numa_node_lspci" ]; then
            echo -e "  - lspci detected NUMA Node: ${numa_node_lspci}"
        else
            echo "  - lspci did not explicitly report NUMA Node (may be inferred)."
        fi

        if [ -n "$numa_node_sysfs" ]; then
            echo -e "  - /sys/class/net/.../device/numa_node: ${numa_node_sysfs}"
            if [ "$numa_node_sysfs" -eq "-1" ]; then
                echo -e "${YELLOW}    (Value -1 means no specific NUMA affinity reported, kernel will try to optimize.)"
            elif [ "$numa_node_sysfs" != "$numa_node_lspci" ] && [ -n "$numa_node_lspci" ]; then
                echo -e "${RED}    WARNING: Discrepancy between lspci and sysfs for NUMA node! Trusting sysfs for process affinity.${NC}"
            fi
        else
            echo "  - Could not read NUMA node from /sys/class/net/.../device/numa_node."
        fi
        echo ""
    done
    echo -e "${YELLOW}Tip:${NC} It's critical to align network-intensive processes with the NUMA node of their corresponding NICs to minimize memory access latency across sockets."
    echo ""
}

# --- Section 4: Practical Usage & Tips ---
print_usage_tips() {
    echo -e "${BLUE}--- Practical Usage & Optimization Tips ---${NC}"
    echo -e "Your system has ${GREEN}$(lscpu | grep "Socket(s)" | awk '{print $NF}') physical sockets${NC} and ${GREEN}$(lscpu | grep "NUMA node(s)" | awk '{print $NF}') NUMA nodes${NC}."
    echo -e "Total Logical CPUs: ${GREEN}$(lscpu | grep "CPU(s):" | head -n 1 | awk '{print $NF}')${NC}"
    echo ""

    echo -e "${BLUE}1. Understanding Your NUMA Nodes:${NC}"
    echo -e "   - ${GREEN}NUMA Node 0 (Socket 0):${NC} CPUs $(numactl --hardware | grep "node 0 cpus:" | cut -d':' -f2 | xargs)"
    echo -e "   - ${GREEN}NUMA Node 1 (Socket 1):${NC} CPUs $(numactl --hardware | grep "node 1 cpus:" | cut -d':' -f2 | xargs)"
    echo ""
    echo -e "${BLUE}2. Pinning Processes (Affinity) - The Core Concept:${NC}"
    echo -e "   - ${YELLOW}Goal:${NC} Keep processes and their data on the same NUMA node to maximize local memory access and reduce inter-socket communication (NUMA penalty)."
    echo ""
    echo -e "${BLUE}3. How to Instance Processes with NUMA Affinity:${NC}"
    echo -e "   Use the '${GREEN}numactl${NC}' command prefix."
    echo -e "   Syntax: ${GREEN}numactl --cpunodebind=<node_id> --membind=<node_id> [optional: taskset -c <cpu_list>] <your_program> [args]${NC}"
    echo ""
    echo -e "   ${GREEN}Example 1: Run a compute-intensive app on NUMA Node 1:${NC}"
    echo -e "     (Assumes 'compute_app' is not network-bound)"
    echo -e "     ${YELLOW}numactl --cpunodebind=1 --membind=1 /path/to/compute_app${NC}"
    echo -e "     ${NC}This dedicates 'compute_app' to the second socket's CPUs and local memory."
    echo ""
    echo -e "   ${GREEN}Example 2: Run a network-intensive app on NUMA Node 0:${NC}"
    echo -e "     (Assumes your NICs are all on NUMA Node 0, as detected by this script)"
    echo -e "     ${YELLOW}numactl --cpunodebind=0 --membind=0 /path/to/network_app${NC}"
    echo -e "     ${NC}This ensures 'network_app' processes data locally to its network interfaces."
    echo ""
    echo -e "   ${GREEN}Example 3: Pin a specific thread/process to a single logical CPU (e.g., CPU 0 on Node 0):${NC}"
    echo -e "     ${YELLOW}numactl --cpunodebind=0 --membind=0 taskset -c 0 /path/to/single_threaded_app${NC}"
    echo -e "     ${NC}Useful for ultra-low latency or debugging, but often not for high throughput."
    echo ""
    echo -e "${BLUE}4. Managing Running Processes:${NC}"
    echo -e "   - Find a process PID: ${YELLOW}ps aux | grep <process_name>${NC}"
    echo -e "   - Modify CPU affinity of running process: ${YELLOW}taskset -pc <cpu_list> <PID>${NC}"
    echo -e "   - Modify NUMA affinity of running process (may not reallocate existing memory): ${YELLOW}numactl --cpunodebind=<node_id> --membind=<node_id> --pid <PID>${NC}"
    echo ""
    echo -e "${BLUE}5. Advanced Tips for Network Performance:${NC}"
    echo -e "   - ${YELLOW}IRQ Affinity:${NC} For very high network throughput, manually assign IRQs for your NICs to specific CPUs within their local NUMA node."
    echo -e "     - Disable ${GREEN}'irqbalance'${NC} if running: ${YELLOW}sudo systemctl stop irqbalance && sudo systemctl disable irqbalance${NC}"
    echo -e "     - Check IRQs: ${YELLOW}cat /proc/interrupts${NC}"
    echo -e "     - Set affinity (example for IRQ 123 to CPU 0): ${YELLOW}echo 1 > /proc/irq/123/smp_affinity${NC}"
    echo -e "   - ${YELLOW}Receive Side Scaling (RSS):${NC} If your NIC supports it, configure RSS queues to distribute incoming network traffic across multiple CPUs within the same NUMA node for parallel processing."
    echo -e "     - Check queues: ${YELLOW}ethtool -l <interface_name>${NC}"
    echo -e "     - Adjust queues/channels: ${YELLOW}sudo ethtool -L <interface_name> combined <N>${NC}"
    echo -e "     - Set RSS affinity for queues: Consult specific NIC documentation (often via `set_irq_affinity.sh` scripts or `ethtool -X`)."
    echo ""
    echo -e "${BLUE}6. SMT (Hyperthreading) Considerations:${NC}"
    echo -e "   - ${YELLOW}Enabled (default):${NC} Good for mixed workloads, improves CPU utilization by allowing two threads per physical core. Best for average server loads."
    echo -e "   - ${YELLOW}Disabled (in BIOS/UEFI):${NC} Each logical core becomes a dedicated physical core. Can improve performance and predictability for extremely latency-sensitive or compute-bound single-threaded applications by eliminating resource contention within a physical core. Consider if your application is single-threaded or if its performance is bottlenecked by shared core resources."
    echo ""
    echo -e "${BLUE}--- End of Insight Report ---${NC}"
}

# --- Main Script Execution ---
check_commands
print_system_overview
print_numa_topology
print_pci_numa_affinity
print_usage_tips
