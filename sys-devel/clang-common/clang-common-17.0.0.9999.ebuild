# Copyright 1999-2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

inherit bash-completion-r1 llvm.org multilib

DESCRIPTION="Common files shared between multiple slots of clang"
HOMEPAGE="https://llvm.org/"

LICENSE="Apache-2.0-with-LLVM-exceptions UoI-NCSA"
SLOT="0"
KEYWORDS=""
IUSE="
	default-compiler-rt default-libcxx default-lld llvm-libunwind
	hardened stricter
"

PDEPEND="
	sys-devel/clang:*
	default-compiler-rt? (
		sys-devel/clang-runtime[compiler-rt]
		llvm-libunwind? ( sys-libs/llvm-libunwind[static-libs] )
		!llvm-libunwind? ( sys-libs/libunwind[static-libs] )
	)
	!default-compiler-rt? ( sys-devel/gcc )
	default-libcxx? ( >=sys-libs/libcxx-${PV}[static-libs] )
	!default-libcxx? ( sys-devel/gcc )
	default-lld? ( sys-devel/lld )
	!default-lld? ( sys-devel/binutils )
"
IDEPEND="
	!default-compiler-rt? ( sys-devel/gcc-config )
	!default-libcxx? ( sys-devel/gcc-config )
"

LLVM_COMPONENTS=( clang/utils )
llvm.org_set_globals

pkg_pretend() {
	[[ ${CLANG_IGNORE_DEFAULT_RUNTIMES} ]] && return

	local flag missing_flags=()
	for flag in default-{compiler-rt,libcxx,lld}; do
		if ! use "${flag}" && has_version "sys-devel/clang[${flag}]"; then
			missing_flags+=( "${flag}" )
		fi
	done

	if [[ ${missing_flags[@]} ]]; then
		eerror "It seems that you have the following flags set on sys-devel/clang:"
		eerror
		eerror "  ${missing_flags[*]}"
		eerror
		eerror "The default runtimes are now set via flags on sys-devel/clang-common."
		eerror "The build is being aborted to prevent breakage.  Please either set"
		eerror "the respective flags on this ebuild, e.g.:"
		eerror
		eerror "  sys-devel/clang-common ${missing_flags[*]}"
		eerror
		eerror "or build with CLANG_IGNORE_DEFAULT_RUNTIMES=1."
		die "Mismatched defaults detected between sys-devel/clang and sys-devel/clang-common"
	fi
}

doclang_cfg() {
	local triple="${1}"

	local tool
	for tool in ${triple}-clang{,++,-cpp}; do
		newins - "${tool}.cfg" <<-EOF
			# This configuration file is used by ${tool} driver.
			@gentoo-common.cfg
		EOF
	done

	# Install symlinks for triples with other vendor strings since some
	# programs insist on mangling the triple.
	local vendor
	for vendor in gentoo pc unknown; do
		local vendor_triple="${triple%%-*}-${vendor}-${triple#*-*-}"
		for tool in clang{,++,-cpp}; do
			if [[ ! -f "${ED}/etc/clang/${vendor_triple}-${tool}.cfg" ]]; then
				dosym "${triple}-${tool}.cfg" "/etc/clang/${vendor_triple}-${tool}.cfg"
			fi
		done
	done
}

src_install() {
	newbashcomp bash-autocomplete.sh clang

	insinto /etc/clang
	newins - gentoo-runtimes.cfg <<-EOF
		# This file is initially generated by sys-devel/clang-runtime.
		# It is used to control the default runtimes using by clang.

		--rtlib=$(usex default-compiler-rt compiler-rt libgcc)
		--unwindlib=$(usex default-compiler-rt libunwind libgcc)
		--stdlib=$(usex default-libcxx libc++ libstdc++)
		-fuse-ld=$(usex default-lld lld bfd)
	EOF

	newins - gentoo-gcc-install.cfg <<-EOF
		# This file is maintained by gcc-config.
		# It is used to specify the selected GCC installation.
	EOF

	newins - gentoo-common.cfg <<-EOF
		# This file contains flags common to clang, clang++ and clang-cpp.
		@gentoo-runtimes.cfg
		@gentoo-gcc-install.cfg
		@gentoo-hardened.cfg
		# bug #870001
		-include "${EPREFIX}/usr/include/gentoo/maybe-stddefs.h"
	EOF

	# Baseline hardening (bug #851111)
	newins - gentoo-hardened.cfg <<-EOF
		# Some of these options are added unconditionally, regardless of
		# USE=hardened, for parity with sys-devel/gcc.
		-fstack-clash-protection
		-fstack-protector-strong
		-fPIE
		-include "${EPREFIX}/usr/include/gentoo/fortify.h"

		-Wl,-z,relro
	EOF

	dodir /usr/include/gentoo

	cat >> "${ED}/usr/include/gentoo/maybe-stddefs.h" <<-EOF || die
	/* __has_include is an extension, but it's fine, because this is only
	for Clang anyway. */
	#if defined __has_include && __has_include (<stdc-predef.h>) && !defined(__GLIBC__)
	# include <stdc-predef.h>
	#endif
	EOF

	local fortify_level=$(usex hardened 3 2)
	# We have to do this because glibc's headers warn if F_S is set
	# without optimization and that would at the very least be very noisy
	# during builds and at worst trigger many -Werror builds.
	cat >> "${ED}/usr/include/gentoo/fortify.h" <<- EOF || die
	#ifdef __clang__
	# pragma clang system_header
	#endif
	#ifndef _FORTIFY_SOURCE
	# if defined(__has_feature)
	#  define __GENTOO_HAS_FEATURE(x) __has_feature(x)
	# else
	#  define __GENTOO_HAS_FEATURE(x) 0
	# endif
	#
	# if defined(__OPTIMIZE__) && __OPTIMIZE__ > 0
	#  if !defined(__SANITIZE_ADDRESS__) && !__GENTOO_HAS_FEATURE(address_sanitizer) && !__GENTOO_HAS_FEATURE(memory_sanitizer)
	#   define _FORTIFY_SOURCE ${fortify_level}
	#  endif
	# endif
	# undef __GENTOO_HAS_FEATURE
	#endif
	EOF

	if use hardened ; then
		cat >> "${ED}/etc/clang/gentoo-hardened.cfg" <<-EOF || die
			# Options below are conditional on USE=hardened.
			-D_GLIBCXX_ASSERTIONS

			# Analogue to GLIBCXX_ASSERTIONS
			# https://libcxx.llvm.org/UsingLibcxx.html#assertions-mode
			# https://libcxx.llvm.org/Hardening.html#using-hardened-mode
			-D_LIBCPP_ENABLE_HARDENED_MODE=1

			-Wl,-z,now
		EOF
	fi

	if use stricter; then
		newins - gentoo-stricter.cfg <<-EOF
			# This file increases the strictness of older clang versions
			# to match the newest upstream version.

			# clang-16 defaults
			-Werror=implicit-function-declaration
			-Werror=implicit-int
			-Werror=incompatible-function-pointer-types

			# constructs banned by C2x
			-Werror=deprecated-non-prototype

			# deprecated but large blast radius
			#-Werror=strict-prototypes
		EOF

		cat >> "${ED}/etc/clang/gentoo-common.cfg" <<-EOF || die
			@gentoo-stricter.cfg
		EOF
	fi

	# We only install config files for supported ABIs because unprefixed tools
	# might be used for crosscompilation where e.g. PIE may not be supported.
	# See bug #912237 and bug #901247.
	doclang_cfg "${CHOST}"

	# Just ${CHOST} won't do due to bug #912685.
	local abi
	for abi in $(get_all_abis); do
		local abi_chost=$(get_abi_CHOST "${abi}")
		doclang_cfg "${abi_chost}"
	done
}

pkg_preinst() {
	if has_version -b sys-devel/gcc-config && has_version sys-devel/gcc
	then
		local gcc_path=$(gcc-config --get-lib-path 2>/dev/null)
		if [[ -n ${gcc_path} ]]; then
			cat >> "${ED}/etc/clang/gentoo-gcc-install.cfg" <<-EOF
				--gcc-install-dir="${gcc_path%%:*}"
			EOF
		fi
	fi
}
