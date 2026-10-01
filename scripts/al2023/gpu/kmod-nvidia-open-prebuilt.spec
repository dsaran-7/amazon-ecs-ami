# Local, AMI-build-time RPM that owns prebuilt NVIDIA open kernel modules (POC M4).
# rpmbuild -bb --define "kver <uname -r>" --define "krel <kver with - -> _>" --define "nvver 595.91.07"
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

Name:           kmod-nvidia-open-prebuilt
Epoch:          3
Version:        %{nvver}
Release:        1.k%{krel}
Summary:        Prebuilt NVIDIA open GPU kernel modules %{nvver} for kernel %{kver} (ECS POC)
License:        MIT and GPLv2
BuildArch:      x86_64
AutoReqProv:    no
Provides:       nvidia-kmod = %{epoch}:%{version}
Requires:       nvidia-kmod-common = %{epoch}:%{version}
Requires:       kernel-uname-r = %{kver}
Requires(post): kmod
Requires(postun): kmod
Conflicts:      kmod-nvidia-open-dkms
Conflicts:      kmod-nvidia-latest-dkms

%description
nvidia, nvidia-modeset, nvidia-drm, nvidia-uvm and nvidia-peermem built at AMI build time from the
kmod-nvidia-open-dkms-%{nvver} sources for kernel %{kver} (strip -g). Replaces the DKMS package so that
no compiler, DKMS or dracut run is needed at boot. Installed under updates/ so it wins over any
DKMS-installed extra/nvidia*.ko (depmod default search order: updates, built-in).

%install
install -d %{buildroot}/lib/modules/%{kver}/updates/nvidia-prebuilt
install -m 0644 %{_sourcedir}/*.ko %{buildroot}/lib/modules/%{kver}/updates/nvidia-prebuilt/

%post
/usr/sbin/depmod -a %{kver} || :

%postun
/usr/sbin/depmod -a %{kver} || :

%files
%dir /lib/modules/%{kver}/updates/nvidia-prebuilt
/lib/modules/%{kver}/updates/nvidia-prebuilt/*.ko
