package Brocken v0.0.1 {
    use v5.42;
    use feature qw[class];
    no warnings qw[experimental::class];
    use Brocken::Katsuro;
    use Brocken::Lindsay;
    use Brocken::Jenny;
    use Brocken::Jenny::Codegen::X86_64;
    use Brocken::Jenny::Codegen::ARM64;
    use Brocken::Jenny::Codegen::RISCV64;
    use Brocken::Jenny::Linker::MachO;
    use Brocken::Jenny::Linker::PE;
    use Brocken::Jenny::Linker::ELF64;
    use File::Temp;

    class Brocken {
        field $platform : param = undef;
        field $codegen;
        field $linker;
        field $ext;
        field $tmpdir_obj;
        method tmpdir () { return $tmpdir_obj->dirname }
        ADJUST {
            $tmpdir_obj = File::Temp->newdir( CLEANUP => 1 );
            $platform //= Brocken::Katsuro::Platform::parse();
            if ( $platform->is_arm64 && $platform->is_macos ) {
                $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
                $linker  = Brocken::Jenny::Linker::MachO->new();
                $ext     = '';
            }
            elsif ( $platform->is_arm64 && $platform->is_windows ) {
                $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
                $linker  = Brocken::Jenny::Linker::PE->new();
                $ext     = '.exe';
            }
            elsif ( $platform->is_arm64 ) {
                $codegen = Brocken::Jenny::Codegen::ARM64->new( platform => $platform );
                $linker  = Brocken::Jenny::Linker::ELF64->new();
                $ext     = '';
            }
            elsif ( $platform->is_riscv64 ) {
                $codegen = Brocken::Jenny::Codegen::RISCV64->new( platform => $platform );
                $linker  = Brocken::Jenny::Linker::ELF64->new();
                $ext     = '';
            }
            elsif ( $platform->is_x64 && $platform->is_macos ) {
                $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                $linker  = Brocken::Jenny::Linker::MachO->new();
                $ext     = '';
            }
            elsif ( $platform->is_x64 && $platform->is_windows ) {
                $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                $linker  = Brocken::Jenny::Linker::PE->new();
                $ext     = '.exe';
            }
            elsif ( $platform->is_x64 ) {
                $codegen = Brocken::Jenny::Codegen::X86_64->new( platform => $platform );
                $linker  = Brocken::Jenny::Linker::ELF64->new();
                $ext     = '';
            }
            else {
                die "Unsupported platform for Brocken: " . $platform->friendly;
            }
        }
        method platform() { return $platform }
        method codegen()  { return $codegen }
        method linker()   { return $linker }
        method ext()      { return $ext }
    }
};
1;
__END__

=pod

=head1 NAME

Brocken - A thing to waste my time on.

=head1 Description

Idk...

=head1 Status

Expect breakage.

=head1 AUTHOR

Sanko Robinson

=head1 LICENSE & LEGAL

This software is Copyright (c) 2026 by Sanko Robinson.

Artistic-2.0 or MIT. You decide.

=cut

