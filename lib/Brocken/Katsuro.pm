package Brocken::Katsuro v0.0.1 {
    use v5.42;
    use feature qw[class];
    use Brocken::Katsuro::Platform;
    use Brocken::Katsuro::Platform::Linux;
    use Brocken::Katsuro::Platform::MacOS;
    use Brocken::Katsuro::Platform::Windows;
    use Brocken::Katsuro::Platform::BSD;
    use Brocken::Katsuro::Platform::Haiku;
    use Brocken::Katsuro::Platform::Solaris;
    use Brocken::Katsuro::Platform::Wasm;
    use Brocken::Katsuro::Platform::ABI;
    use Brocken::Katsuro::Platform::ABI::X86_64;
    use Brocken::Katsuro::Platform::ABI::AArch64;
    use Brocken::Katsuro::Platform::ABI::RISCV64;
};

=pod

=encoding utf-8

=head1 NAME

Brocken::Katsuro - Platform and Architecture Abstraction Layer

=head1 DESCRIPTION

This package handles the detection, normalization, and abstraction of target
platforms (OS and Architecture). It provides a unified interface for querying
syscall numbers, register sets, and binary format requirements.

=head2 Target Triples

Brocken uses a four-part "normalized" triple format: C<arch-vendor-os-env>.

=over 4

=item * B<arch>: x86_64, aarch64, riscv64, etc.

=item * B<vendor>: pc, apple, unknown, etc.

=item * B<os>: linux, darwin, windows, freebsd, netbsd, openbsd, dragonfly, haiku, solaris, wasi.

=item * B<env>: gnu, msvc, macho, elf, wasi, musl, etc.

=back

=head2 References

=over 4

=item * Target Triplet Wiki: L<https://wiki.osdev.org/Target_Triplet>

=item * LLVM Triple Header: L<https://llvm.org/doxygen/Triple_8h_source.html>

=back

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
