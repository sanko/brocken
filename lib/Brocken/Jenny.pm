package Brocken::Jenny v0.0.1 {
    use v5.42;
    use feature qw[class];
    no warnings qw[experimental::class];
    use Brocken::Jenny::Codegen::X86_64;
    use Brocken::Jenny::Codegen::ARM64;
    use Brocken::Jenny::Codegen::RISCV64;
    use Brocken::Jenny::Codegen::Wasm;
    use Brocken::Jenny::MIR;
    use Brocken::Jenny::RegAlloc;
    use Brocken::Jenny::Lowerer::X86_64;
    use Brocken::Jenny::Lowerer::ARM64;
    use Brocken::Jenny::Lowerer::RISCV64;
    use Brocken::Jenny::Lowerer::Wasm;
    use Brocken::Jenny::Linker;
    use Brocken::Jenny::Linker::Layout;
    use Brocken::Jenny::Linker::DWARF;
    use Brocken::Jenny::Linker::MachO;
    use Brocken::Jenny::Linker::PE;
    use Brocken::Jenny::Linker::ELF64;
    use Brocken::Jenny::Linker::Wasm;
};

=pod

=encoding utf-8

=head1 NAME

Brocken::Jenny - Machine Code Generation and Linking Layer

=head1 DESCRIPTION

Jenny is responsible for lowering Lindsay IR into native machine code (Jenny::Codegen) and packaging those bytes into
executable binary formats like ELF, Mach-O, or PE (Jenny::Linker).

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
