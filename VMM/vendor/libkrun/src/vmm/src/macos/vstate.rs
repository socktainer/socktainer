// Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
//
// Portions Copyright 2017 The Chromium OS Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the THIRD-PARTY file.

use std::cell::Cell;
use std::collections::{BTreeMap, HashMap};
use std::fmt::{Display, Formatter};
use std::io;
use std::result;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use super::super::{FC_EXIT_CODE_GENERIC_ERROR, FC_EXIT_CODE_OK};
use crate::vmm_config::machine_config::CpuFeaturesTemplate;

use arch::ArchMemoryInfo;
use crossbeam_channel::{unbounded, Receiver, RecvTimeoutError, Sender};
use devices::legacy::VcpuList;
use hvf::{HvfVcpu, HvfVm, VcpuExit, Vcpus};
use utils::eventfd::EventFd;
use vm_memory::{
    Address, GuestAddress, GuestMemory, GuestMemoryError, GuestMemoryMmap, GuestMemoryRegion,
};

/// Errors associated with the wrappers over KVM ioctls.
#[derive(Debug)]
pub enum Error {
    /// Invalid guest memory configuration.
    GuestMemoryMmap(GuestMemoryError),
    /// The number of configured slots is bigger than the maximum reported by KVM.
    NotEnoughMemorySlots,
    /// Error configuring the general purpose aarch64 registers.
    REGSConfiguration(arch::aarch64::regs::Error),
    /// Cannot set the memory regions.
    SetUserMemoryRegion(hvf::Error),
    /// Failed to signal Vcpu.
    SignalVcpu(utils::errno::Error),
    /// Error doing Vcpu Init on Arm.
    VcpuArmInit,
    /// Error getting the Vcpu preferred target on Arm.
    VcpuArmPreferredTarget,
    /// vCPU count is not initialized.
    VcpuCountNotInitialized,
    /// Cannot run the VCPUs.
    VcpuRun,
    /// Cannot spawn a new vCPU thread.
    VcpuSpawn(io::Error),
    /// Cannot cleanly initialize vcpu TLS.
    VcpuTlsInit,
    /// Vcpu not present in TLS.
    VcpuTlsNotPresent,
    /// Unexpected KVM_RUN exit reason
    VcpuUnhandledKvmExit,
    /// Cannot configure the microvm.
    VmSetup(hvf::Error),
}

impl Display for Error {
    fn fmt(&self, f: &mut Formatter) -> std::fmt::Result {
        use self::Error::*;

        match self {
            GuestMemoryMmap(e) => write!(f, "Guest memory error: {e:?}"),
            VcpuCountNotInitialized => write!(f, "vCPU count is not initialized"),
            VmSetup(e) => write!(f, "Cannot configure the microvm: {e:?}"),
            VcpuRun => write!(f, "Cannot run the VCPUs"),
            NotEnoughMemorySlots => write!(
                f,
                "The number of configured slots is bigger than the maximum reported by KVM"
            ),
            SetUserMemoryRegion(e) => write!(f, "Cannot set the memory regions: {e:?}"),
            SignalVcpu(e) => write!(f, "Failed to signal Vcpu: {e}"),
            REGSConfiguration(e) => write!(
                f,
                "Error configuring the general purpose aarch64 registers: {e:?}"
            ),
            VcpuSpawn(e) => write!(f, "Cannot spawn a new vCPU thread: {e}"),
            VcpuTlsInit => write!(f, "Cannot clean init vcpu TLS"),
            VcpuTlsNotPresent => write!(f, "Vcpu not present in TLS"),
            VcpuUnhandledKvmExit => write!(f, "Unexpected KVM_RUN exit reason"),
            VcpuArmPreferredTarget => write!(f, "Error getting the Vcpu preferred target on Arm"),
            VcpuArmInit => write!(f, "Error doing Vcpu Init on Arm"),
        }
    }
}

pub type Result<T> = result::Result<T, Error>;

/// A wrapper around creating and using a VM.
pub struct Vm {
    hvf_vm: Arc<HvfVm>,
}

impl Vm {
    /// Constructs a new `Vm` using the given `Kvm` instance.
    pub fn new(nested_enabled: bool) -> Result<Self> {
        let hvf_vm = HvfVm::new(nested_enabled).map_err(Error::VmSetup)?;

        Ok(Vm {
            hvf_vm: Arc::new(hvf_vm),
        })
    }

    pub fn hvf_vm(&self) -> &HvfVm {
        &self.hvf_vm
    }

    pub fn memory_reclaimer(&self, memory: GuestMemoryMmap) -> Arc<MemoryReclaimer> {
        Arc::new(MemoryReclaimer::new(self.hvf_vm.clone(), memory))
    }

    /// Initializes the guest memory.
    pub fn memory_init(&mut self, guest_mem: &GuestMemoryMmap) -> Result<()> {
        for region in guest_mem.iter() {
            // It's safe to unwrap because the guest address is valid.
            let host_addr = guest_mem.get_host_address(region.start_addr()).unwrap();
            debug!(
                "Guest memory host_addr={:x?} guest_addr={:x?} len={:x?}",
                host_addr,
                region.start_addr().raw_value(),
                region.len()
            );
            self.hvf_vm
                .map_memory(
                    host_addr as u64,
                    region.start_addr().raw_value(),
                    region.len(),
                )
                .map_err(Error::SetUserMemoryRegion)?;
        }

        Ok(())
    }

    pub fn add_mapping(
        &self,
        reply_sender: Sender<bool>,
        host_addr: u64,
        guest_addr: u64,
        len: u64,
    ) {
        debug!("add_mapping: host_addr={host_addr:x}, guest_addr={guest_addr:x}, len={len}");
        if let Err(e) = self.hvf_vm.unmap_memory(guest_addr, len) {
            error!("Error removing memory map: {e:?}");
        }

        if let Err(e) = self.hvf_vm.map_memory(host_addr, guest_addr, len) {
            error!("Error adding memory map: {e:?}");
            reply_sender.send(false).unwrap();
        } else {
            reply_sender.send(true).unwrap();
        }
    }

    pub fn remove_mapping(&self, reply_sender: Sender<bool>, guest_addr: u64, len: u64) {
        debug!("remove_mapping: guest_addr={guest_addr:x}, len={len}");
        if let Err(e) = self.hvf_vm.unmap_memory(guest_addr, len) {
            error!("Error removing memory map: {e:?}");
            reply_sender.send(false).unwrap();
        } else {
            reply_sender.send(true).unwrap();
        }
    }
}

#[derive(Default)]
struct ReleasedRanges {
    ranges: BTreeMap<u64, u64>,
}

impl ReleasedRanges {
    fn insert(&mut self, start: u64, end: u64) -> io::Result<()> {
        if self
            .ranges
            .range(..end)
            .next_back()
            .is_some_and(|(&other_start, &other_end)| other_end > start && other_start < end)
        {
            return Err(io::Error::from_raw_os_error(libc::EINVAL));
        }
        self.ranges.insert(start, end);
        Ok(())
    }

    fn take_containing(&mut self, address: u64) -> Option<(u64, u64)> {
        let (&start, &end) = self.ranges.range(..=address).next_back()?;
        if address >= end {
            return None;
        }
        self.ranges.remove(&start);
        Some((start, end))
    }
}

/// Owns the macOS stage-2 state for guest pages returned by virtio-balloon.
/// The host virtual mapping remains allocated so a later guest fault can
/// restore the same zero-filled range without changing guest addresses.
pub struct MemoryReclaimer {
    hvf_vm: Arc<HvfVm>,
    memory: GuestMemoryMmap,
    released: Mutex<ReleasedRanges>,
    page_size: u64,
}

fn validated_host_range(
    memory: &GuestMemoryMmap,
    page_size: u64,
    start: u64,
    len: u64,
) -> io::Result<*mut u8> {
    let end = start
        .checked_add(len)
        .filter(|_| len != 0)
        .ok_or_else(|| io::Error::from_raw_os_error(libc::EINVAL))?;
    if !start.is_multiple_of(page_size) || !len.is_multiple_of(page_size) {
        return Err(io::Error::from_raw_os_error(libc::EINVAL));
    }
    let host_start = memory
        .get_host_address(GuestAddress(start))
        .map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
    let host_last = memory
        .get_host_address(GuestAddress(end - 1))
        .map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
    if (host_last as usize).wrapping_sub(host_start as usize) != len as usize - 1 {
        return Err(io::Error::from_raw_os_error(libc::EINVAL));
    }
    Ok(host_start)
}

impl MemoryReclaimer {
    fn new(hvf_vm: Arc<HvfVm>, memory: GuestMemoryMmap) -> Self {
        let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        Self {
            hvf_vm,
            memory,
            released: Mutex::new(ReleasedRanges::default()),
            page_size: u64::try_from(page_size).expect("invalid host page size"),
        }
    }

    fn validated_host_range(&self, start: u64, len: u64) -> io::Result<*mut u8> {
        validated_host_range(&self.memory, self.page_size, start, len)
    }

    pub fn restore_fault(&self, address: u64) -> bool {
        let mut released = self.released.lock().unwrap();
        let Some((start, end)) = released.take_containing(address) else {
            return false;
        };
        let len = end - start;
        let host = self
            .validated_host_range(start, len)
            .expect("tracked released range is no longer valid guest RAM");
        let reused = unsafe {
            libc::madvise(
                host.cast::<libc::c_void>(),
                len as usize,
                libc::MADV_FREE_REUSE,
            )
        } == 0;
        if !reused || self.hvf_vm.map_memory(host as u64, start, len).is_err() {
            if reused {
                unsafe {
                    libc::madvise(
                        host.cast::<libc::c_void>(),
                        len as usize,
                        libc::MADV_FREE_REUSABLE,
                    )
                };
            }
            let _ = released.insert(start, end);
            panic!("failed to restore a released guest RAM range");
        }
        true
    }
}

impl devices::virtio::balloon::FreePageReclaimer for MemoryReclaimer {
    fn release_range(
        &self,
        _mem: &GuestMemoryMmap,
        guest_addr: GuestAddress,
        len: u64,
    ) -> io::Result<()> {
        let start = guest_addr.raw_value();
        let end = start
            .checked_add(len)
            .ok_or_else(|| io::Error::from_raw_os_error(libc::EINVAL))?;
        let host = self.validated_host_range(start, len)?;
        let mut released = self.released.lock().unwrap();
        released.insert(start, end)?;
        if self.hvf_vm.unmap_memory(start, len).is_err() {
            released.take_containing(start);
            return Err(io::Error::other("failed to unmap guest memory"));
        }
        if unsafe {
            libc::madvise(
                host.cast::<libc::c_void>(),
                len as usize,
                libc::MADV_FREE_REUSABLE,
            )
        } != 0
        {
            let error = io::Error::last_os_error();
            let _ = self.hvf_vm.map_memory(host as u64, start, len);
            released.take_containing(start);
            return Err(error);
        }
        Ok(())
    }
}

/// Encapsulates configuration parameters for the guest vCPUS.
#[derive(Debug, Eq, PartialEq)]
pub struct VcpuConfig {
    /// Number of guest VCPUs.
    pub vcpu_count: u8,
    /// Enable hyperthreading in the CPUID configuration.
    pub ht_enabled: bool,
    /// CPUID template to use.
    pub cpu_template: Option<CpuFeaturesTemplate>,
}

// Using this for easier explicit type-casting to help IDEs interpret the code.
type VcpuCell = Cell<Option<*const Vcpu>>;

/// A wrapper around creating and using a kvm-based VCPU.
pub struct Vcpu {
    id: u8,
    boot_entry_addr: u64,
    boot_receiver: Option<Receiver<u64>>,
    boot_senders: Option<HashMap<u64, Sender<u64>>>,
    fdt_addr: u64,
    mmio_bus: Option<devices::Bus>,
    #[cfg_attr(all(test, target_arch = "aarch64"), allow(unused))]
    exit_evt: EventFd,

    #[cfg(target_arch = "aarch64")]
    mpidr: u64,

    #[allow(unused)]
    event_receiver: Receiver<VcpuEvent>,
    // The transmitting end of the events channel which will be given to the handler.
    event_sender: Option<Sender<VcpuEvent>>,
    // The receiving end of the responses channel which will be given to the handler.
    response_receiver: Option<Receiver<VcpuResponse>>,
    // The transmitting end of the responses channel owned by the vcpu side.
    response_sender: Sender<VcpuResponse>,

    vcpu_list: Arc<VcpuList>,
    nested_enabled: bool,
    memory_reclaimer: Option<Arc<MemoryReclaimer>>,
}

impl Vcpu {
    thread_local!(static TLS_VCPU_PTR: VcpuCell = const { Cell::new(None) });

    /// Associates `self` with the current thread.
    ///
    /// It is a prerequisite to successfully run `init_thread_local_data()` before using
    /// `run_on_thread_local()` on the current thread.
    /// This function will return an error if there already is a `Vcpu` present in the TLS.
    fn init_thread_local_data(&mut self) -> Result<()> {
        Self::TLS_VCPU_PTR.with(|cell: &VcpuCell| {
            if cell.get().is_some() {
                return Err(Error::VcpuTlsInit);
            }
            cell.set(Some(self as *const Vcpu));
            Ok(())
        })
    }

    /// Deassociates `self` from the current thread.
    ///
    /// Should be called if the current `self` had called `init_thread_local_data()` and
    /// now needs to move to a different thread.
    ///
    /// Fails if `self` was not previously associated with the current thread.
    fn reset_thread_local_data(&mut self) -> Result<()> {
        // Best-effort to clean up TLS. If the `Vcpu` was moved to another thread
        // _before_ running this, then there is nothing we can do.
        Self::TLS_VCPU_PTR.with(|cell: &VcpuCell| {
            if let Some(vcpu_ptr) = cell.get() {
                if std::ptr::eq(vcpu_ptr, self) {
                    Self::TLS_VCPU_PTR.with(|cell: &VcpuCell| cell.take());
                    return Ok(());
                }
            }
            Err(Error::VcpuTlsNotPresent)
        })
    }

    /// Registers a signal handler which makes use of TLS and kvm immediate exit to
    /// kick the vcpu running on the current thread, if there is one.
    pub fn register_kick_signal_handler() {
        /*
        extern "C" fn handle_signal(_: c_int, _: *mut siginfo_t, _: *mut c_void) {
            // This is safe because it's temporarily aliasing the `Vcpu` object, but we are
            // only reading `vcpu.fd` which does not change for the lifetime of the `Vcpu`.
            unsafe {
                let _ = Vcpu::run_on_thread_local(|_vcpu| {
                    vcpu.fd.set_kvm_immediate_exit(1);
                    fence(Ordering::Release);
                });
            }
        }
        */

        //register_signal_handler(sigrtmin() + VCPU_RTSIG_OFFSET, handle_signal)
        //    .expect("Failed to register vcpu signal handler");
    }

    /// Constructs a new VCPU for `vm`.
    ///
    /// # Arguments
    ///
    /// * `id` - Represents the CPU number between [0, max vcpus).
    /// * `vm_fd` - The kvm `VmFd` for the virtual machine this vcpu will get attached to.
    /// * `exit_evt` - An `EventFd` that will be written into when this vcpu exits.
    pub fn new_aarch64(
        id: u8,
        boot_entry_addr: GuestAddress,
        boot_receiver: Option<Receiver<u64>>,
        exit_evt: EventFd,
        vcpu_list: Arc<VcpuList>,
        nested_enabled: bool,
    ) -> Result<Self> {
        let (event_sender, event_receiver) = unbounded();
        let (response_sender, response_receiver) = unbounded();

        Ok(Vcpu {
            id,
            boot_entry_addr: boot_entry_addr.raw_value(),
            boot_receiver,
            boot_senders: None,
            fdt_addr: 0,
            mmio_bus: None,
            exit_evt,
            mpidr: id as u64,
            event_receiver,
            event_sender: Some(event_sender),
            response_receiver: Some(response_receiver),
            response_sender,
            vcpu_list,
            nested_enabled,
            memory_reclaimer: None,
        })
    }

    /// Returns the cpu index as seen by the guest OS.
    pub fn cpu_index(&self) -> u8 {
        self.id
    }

    /// Gets the MPIDR register value.
    pub fn get_mpidr(&self) -> u64 {
        self.mpidr
    }

    /// Sets a MMIO bus for this vcpu.
    pub fn set_mmio_bus(&mut self, mmio_bus: devices::Bus) {
        self.mmio_bus = Some(mmio_bus);
    }

    pub fn set_memory_reclaimer(&mut self, reclaimer: Arc<MemoryReclaimer>) {
        self.memory_reclaimer = Some(reclaimer);
    }

    pub fn set_boot_senders(&mut self, boot_senders: HashMap<u64, Sender<u64>>) {
        self.boot_senders = Some(boot_senders);
    }

    /// Configures an aarch64 specific vcpu.
    ///
    /// # Arguments
    ///
    /// * `guest_mem` - The guest memory used by this microvm.
    pub fn configure_aarch64(&mut self, mem_info: &ArchMemoryInfo) -> Result<()> {
        self.fdt_addr = mem_info.fdt_addr;

        Ok(())
    }

    /// Moves the vcpu to its own thread and constructs a VcpuHandle.
    /// The handle can be used to control the remote vcpu.
    pub fn start_threaded(mut self) -> Result<VcpuHandle> {
        let event_sender = self.event_sender.take().unwrap();
        let response_receiver = self.response_receiver.take().unwrap();
        let (init_tls_sender, init_tls_receiver) = unbounded();

        let vcpu_thread = thread::Builder::new()
            .name(format!("fc_vcpu {}", self.cpu_index()))
            .spawn(move || {
                self.init_thread_local_data()
                    .expect("Cannot cleanly initialize vcpu TLS.");

                self.run(init_tls_sender);
            })
            .map_err(Error::VcpuSpawn)?;

        init_tls_receiver
            .recv()
            .expect("Error waiting for TLS initialization.");

        Ok(VcpuHandle::new(
            event_sender,
            response_receiver,
            vcpu_thread,
        ))
    }

    /// Returns error or enum specifying whether emulation was handled or interrupted.
    fn run_emulation(&mut self, hvf_vcpu: &mut HvfVcpu) -> Result<VcpuEmulation> {
        let vcpuid = hvf_vcpu.id();

        let reclaimer = self.memory_reclaimer.clone();
        match hvf_vcpu.run(self.vcpu_list.clone(), &move |address| {
            reclaimer
                .as_ref()
                .is_some_and(|reclaimer| reclaimer.restore_fault(address))
        }) {
            Ok(exit) => match exit {
                VcpuExit::Breakpoint => {
                    debug!("vCPU {vcpuid} breakpoint");
                    Ok(VcpuEmulation::Interrupted)
                }
                VcpuExit::Canceled => {
                    debug!("vCPU {vcpuid} canceled");
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::CpuOn(mpidr, entry, context_id) => {
                    debug!("CpuOn: mpidr=0x{mpidr:x} entry=0x{entry:x} context_id={context_id}");
                    if let Some(boot_senders) = &self.boot_senders {
                        if let Some(sender) = boot_senders.get(&mpidr) {
                            sender.send(entry).unwrap()
                        }
                    } else {
                        error!("CpuOn request coming from an unexpected vCPU={}", self.id);
                    }
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::HypervisorCall => {
                    debug!("vCPU {vcpuid} HVC");
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::MmioRead(addr, data) => {
                    if let Some(ref mmio_bus) = self.mmio_bus {
                        debug!("vCPU {vcpuid} MMIO read 0x{addr:x}");
                        mmio_bus.read(vcpuid, addr, data);
                    }
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::MmioWrite(addr, data) => {
                    if let Some(ref mmio_bus) = self.mmio_bus {
                        mmio_bus.write(vcpuid, addr, data);
                    }
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::MemoryRestored => Ok(VcpuEmulation::Handled),
                VcpuExit::PsciHandled => {
                    debug!("vCPU {vcpuid} PSCI");
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::SecureMonitorCall => {
                    debug!("vCPU {vcpuid} SMC");
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::Shutdown => {
                    info!("vCPU {vcpuid} received shutdown signal");
                    Ok(VcpuEmulation::Stopped)
                }
                VcpuExit::SystemRegister => {
                    debug!("vCPU {vcpuid} accessed a system register");
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::VtimerActivated => {
                    debug!("vCPU {vcpuid} VtimerActivated");
                    self.vcpu_list.set_vtimer_irq(vcpuid);
                    Ok(VcpuEmulation::Handled)
                }
                VcpuExit::WaitForEvent => {
                    debug!("vCPU {vcpuid} WaitForEvent");
                    Ok(VcpuEmulation::WaitForEvent)
                }
                VcpuExit::WaitForEventExpired => {
                    debug!("vCPU {vcpuid} WaitForEventExpired");
                    Ok(VcpuEmulation::WaitForEventExpired)
                }
                VcpuExit::WaitForEventTimeout(duration) => {
                    debug!("vCPU {vcpuid} WaitForEventTimeout timeout={duration:?}");
                    Ok(VcpuEmulation::WaitForEventTimeout(duration))
                }
            },
            Err(e) => panic!("Error running HVF vCPU: {e:?}"),
        }
    }

    /// Main loop of the vCPU thread.
    pub fn run(&mut self, init_tls_sender: Sender<bool>) {
        let mut hvf_vcpu =
            HvfVcpu::new(self.mpidr, self.nested_enabled).expect("Can't create HVF vCPU");
        let hvf_vcpuid = hvf_vcpu.id();

        init_tls_sender
            .send(true)
            .expect("Cannot notify vcpu TLS initialization.");

        let (wfe_sender, wfe_receiver) = unbounded();
        self.vcpu_list.register(hvf_vcpuid, wfe_sender);

        let entry_addr = if let Some(boot_receiver) = &self.boot_receiver {
            boot_receiver.recv().unwrap()
        } else {
            self.boot_entry_addr
        };

        hvf_vcpu
            .set_initial_state(entry_addr, self.fdt_addr)
            .unwrap_or_else(|_| panic!("Can't set HVF vCPU {hvf_vcpuid} initial state"));

        loop {
            match self.run_emulation(&mut hvf_vcpu) {
                // Emulation ran successfully, continue.
                Ok(VcpuEmulation::Handled) => (),
                // Emulation was interrupted by a breakpoint.
                Ok(VcpuEmulation::Interrupted) => self.wait_for_resume(),
                // Wait for an external event.
                Ok(VcpuEmulation::WaitForEvent) => {
                    self.wait_for_event(hvf_vcpuid, &wfe_receiver, None)
                }
                Ok(VcpuEmulation::WaitForEventExpired) => (),
                Ok(VcpuEmulation::WaitForEventTimeout(timeout)) => {
                    self.wait_for_event(hvf_vcpuid, &wfe_receiver, Some(timeout))
                }
                // The guest was rebooted or halted.
                Ok(VcpuEmulation::Stopped) => {
                    self.exit(FC_EXIT_CODE_OK);
                    break;
                }
                // Emulation errors lead to vCPU exit.
                Err(_) => {
                    self.exit(FC_EXIT_CODE_GENERIC_ERROR);
                    break;
                }
            }
        }
    }

    fn wait_for_event(
        &mut self,
        hvf_vcpuid: u64,
        receiver: &Receiver<u32>,
        timeout: Option<Duration>,
    ) {
        if self.vcpu_list.should_wait(hvf_vcpuid) {
            if let Some(timeout) = timeout {
                match receiver.recv_timeout(timeout) {
                    Ok(_) => {}
                    Err(e) => match e {
                        RecvTimeoutError::Timeout => {}
                        RecvTimeoutError::Disconnected => panic!("WFE channel closed unexpectedly"),
                    },
                }
            } else {
                receiver.recv().unwrap();
            }
        }
    }

    fn wait_for_resume(&mut self) {}

    fn exit(&mut self, exit_code: u8) {
        self.response_sender
            .send(VcpuResponse::Exited(exit_code))
            .expect("failed to send Exited status");

        if let Err(e) = self.exit_evt.write(1) {
            error!("Failed signaling vcpu exit event: {e}");
        }
    }
}

impl Drop for Vcpu {
    fn drop(&mut self) {
        let _ = self.reset_thread_local_data();
    }
}

// Allow currently unused Pause and Exit events. These will be used by the vmm later on.
#[allow(unused)]
#[derive(Debug)]
/// List of events that the Vcpu can receive.
pub enum VcpuEvent {
    /// Pause the Vcpu.
    Pause,
    /// Event that should resume the Vcpu.
    Resume,
    // Serialize and Deserialize to follow after we get the support from kvm-ioctls.
}

#[derive(Debug, Eq, PartialEq)]
/// List of responses that the Vcpu reports.
pub enum VcpuResponse {
    /// Vcpu is paused.
    Paused,
    /// Vcpu is resumed.
    Resumed,
    /// Vcpu is stopped.
    Exited(u8),
}

/// Wrapper over Vcpu that hides the underlying interactions with the Vcpu thread.
pub struct VcpuHandle {
    event_sender: Sender<VcpuEvent>,
    response_receiver: Receiver<VcpuResponse>,
}

impl VcpuHandle {
    pub fn new(
        event_sender: Sender<VcpuEvent>,
        response_receiver: Receiver<VcpuResponse>,
        _vcpu_thread: thread::JoinHandle<()>,
    ) -> Self {
        Self {
            event_sender,
            response_receiver,
        }
    }

    pub fn send_event(&self, event: VcpuEvent) -> Result<()> {
        // Use expect() to crash if the other thread closed this channel.
        self.event_sender
            .send(event)
            .expect("event sender channel closed on vcpu end.");
        // Kick the vcpu so it picks up the message.
        /*
        self.vcpu_thread
            .as_ref()
            // Safe to unwrap since constructor make this 'Some'.
            .unwrap()
            .kill(sigrtmin() + VCPU_RTSIG_OFFSET)
            .map_err(Error::SignalVcpu)?;
        */
        Ok(())
    }

    pub fn response_receiver(&self) -> &Receiver<VcpuResponse> {
        &self.response_receiver
    }
}

enum VcpuEmulation {
    Handled,
    Interrupted,
    Stopped,
    WaitForEvent,
    WaitForEventExpired,
    WaitForEventTimeout(Duration),
}

#[cfg(test)]
mod tests {
    #[cfg(target_arch = "x86_64")]
    use crossbeam_channel::RecvTimeoutError;
    use std::sync::Arc;
    #[cfg(target_arch = "x86_64")]
    use std::time::Duration;

    use super::*;
    use arch::aarch64::layout::DRAM_MEM_START_EFI;
    use devices::legacy::VcpuList;
    use vm_memory::{GuestAddress, GuestMemoryMmap};

    // Auxiliary function being used throughout the tests.
    // Does NOT create a real HVF VM — Vcpu::new_aarch64 and most vcpu methods
    // work without one, keeping tests free from the one-VM-per-process limit.
    fn setup_vcpu(mem_size: usize) -> (Vcpu, GuestMemoryMmap) {
        let gm = GuestMemoryMmap::from_ranges(&[(GuestAddress(0), mem_size)]).unwrap();
        let exit_evt = EventFd::new(utils::eventfd::EFD_NONBLOCK).unwrap();
        let vcpu_list = Arc::new(VcpuList::new(1));
        let vcpu = Vcpu::new_aarch64(1, GuestAddress(0), None, exit_evt, vcpu_list, false).unwrap();
        (vcpu, gm)
    }

    #[test]
    fn released_ranges_reject_overlap_and_restore_once() {
        let mut ranges = ReleasedRanges::default();
        ranges.insert(0x4000, 0x8000).unwrap();
        ranges.insert(0x8000, 0xc000).unwrap();
        assert!(ranges.insert(0x6000, 0xa000).is_err());
        assert_eq!(ranges.take_containing(0x5fff), Some((0x4000, 0x8000)));
        assert_eq!(ranges.take_containing(0x5fff), None);
        assert_eq!(ranges.take_containing(0xbfff), Some((0x8000, 0xc000)));
        assert_eq!(ranges.take_containing(0xc000), None);
    }

    #[test]
    fn free_page_ranges_must_be_aligned_contiguous_ram() {
        let memory = GuestMemoryMmap::from_ranges(&[
            (GuestAddress(0x4000), 0x8000),
            (GuestAddress(0x20_000), 0x4000),
        ])
        .unwrap();
        assert!(validated_host_range(&memory, 0x4000, 0x4000, 0x4000).is_ok());
        assert!(validated_host_range(&memory, 0x4000, 0x4001, 0x4000).is_err());
        assert!(validated_host_range(&memory, 0x4000, 0x4000, 0).is_err());
        assert!(validated_host_range(&memory, 0x4000, u64::MAX - 0x1000, 0x4000).is_err());
        assert!(validated_host_range(&memory, 0x4000, 0x8000, 0x20_000).is_err());
    }

    #[test]
    fn test_set_mmio_bus() {
        let (mut vcpu, _) = setup_vcpu(0x1000);
        assert!(vcpu.mmio_bus.is_none());
        vcpu.set_mmio_bus(devices::Bus::new());
        assert!(vcpu.mmio_bus.is_some());
    }

    #[test]
    fn test_vm_memory_init() {
        let mut vm = Vm::new(false).expect("Cannot create new vm");

        // Use a realistic guest physical address; hv_vm_map rejects GPA 0.
        let gm = GuestMemoryMmap::from_ranges(&[(
            GuestAddress(DRAM_MEM_START_EFI),
            0x20_0000, // 2 MB
        )])
        .unwrap();
        vm.memory_init(&gm).expect("memory_init failed");
    }

    #[test]
    fn test_configure_vcpu() {
        // configure_aarch64 only sets fdt_addr — no HVF VM needed.
        let mem_info = arch::ArchMemoryInfo::default();

        // Try it for when vcpu id is 0.
        let vcpu_list = Arc::new(VcpuList::new(1));
        let mut vcpu = Vcpu::new_aarch64(
            0,
            GuestAddress(0),
            None,
            EventFd::new(utils::eventfd::EFD_NONBLOCK).unwrap(),
            vcpu_list,
            false,
        )
        .unwrap();
        assert!(vcpu.configure_aarch64(&mem_info).is_ok());

        // Try it for when vcpu id is NOT 0.
        let vcpu_list = Arc::new(VcpuList::new(2));
        let mut vcpu = Vcpu::new_aarch64(
            1,
            GuestAddress(0),
            None,
            EventFd::new(utils::eventfd::EFD_NONBLOCK).unwrap(),
            vcpu_list,
            false,
        )
        .unwrap();
        assert!(vcpu.configure_aarch64(&mem_info).is_ok());
    }

    #[test]
    fn test_vcpu_tls() {
        let (mut vcpu, _) = setup_vcpu(0x1000);

        // Reset should fail before TLS is initialized.
        assert!(vcpu.reset_thread_local_data().is_err());

        // Initialize vcpu TLS.
        vcpu.init_thread_local_data().unwrap();

        // Reset vcpu TLS.
        assert!(vcpu.reset_thread_local_data().is_ok());

        // Second reset should return error.
        assert!(vcpu.reset_thread_local_data().is_err());
    }

    #[test]
    fn test_invalid_tls() {
        let (mut vcpu, _) = setup_vcpu(0x1000);
        // Initialize vcpu TLS.
        vcpu.init_thread_local_data().unwrap();
        // Trying to initialize non-empty TLS should error.
        vcpu.init_thread_local_data().unwrap_err();
    }

    #[cfg(target_arch = "x86_64")]
    // Sends an event to a vcpu and expects a particular response.
    fn queue_event_expect_response(handle: &VcpuHandle, event: VcpuEvent, response: VcpuResponse) {
        handle
            .send_event(event)
            .expect("failed to send event to vcpu");
        assert_eq!(
            handle
                .response_receiver()
                .recv_timeout(Duration::from_millis(100))
                .expect("did not receive event response from vcpu"),
            response
        );
    }

    #[cfg(target_arch = "x86_64")]
    // Sends an event to a vcpu and expects no response.
    fn queue_event_expect_timeout(handle: &VcpuHandle, event: VcpuEvent) {
        handle
            .send_event(event)
            .expect("failed to send event to vcpu");
        assert_eq!(
            handle
                .response_receiver()
                .recv_timeout(Duration::from_millis(100)),
            Err(RecvTimeoutError::Timeout)
        );
    }
}
