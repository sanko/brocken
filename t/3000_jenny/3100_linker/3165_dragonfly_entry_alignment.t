use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Blib;
use Brocken;
use Brocken::Katsuro::Platform;
use Brocken::Jenny::Linker::ELF64;

# Walks the x86-64 entry stub tracking rsp%16 and records the alignment at every call site.  SysV requires the
# *caller* to execute `call` with rsp%16 == 0 so the callee sees rsp%16 == 8 at entry.
sub walk_stack {
    my ($b) = @_;
    my $mod = 0;
    my @checks;
    my $i    = 0;
    my $n    = length $b;
    while ( $i < $n ) {
        my $here = substr $b, $i;
        if ( substr( $here, 0, 4 ) eq "\x48\x83\xE4\xF0" ) { $mod = 0; $i += 4 }                  # and rsp, -16
        elsif ( substr( $here, 0, 3 ) eq "\x48\x81\xEC" ) { $mod = ( $mod - unpack( 'l<', substr( $here, 3, 4 ) ) ) & 15; $i += 7 }    # sub rsp, imm32
        elsif ( substr( $here, 0, 4 ) eq "\x48\x83\xEC\x08" ) { $mod = ( $mod - 8 ) & 15; $i += 4 }   # sub rsp, 8
        elsif ( substr( $here, 0, 4 ) eq "\x48\x83\xC4\x08" ) { $mod = ( $mod + 8 ) & 15; $i += 4 }   # add rsp, 8
        elsif ( ord($here) == 0x57 ) { $mod = ( $mod - 8 ) & 15; $i += 1 }                            # push rdi
        elsif ( ord($here) == 0x5F ) { $mod = ( $mod + 8 ) & 15; $i += 1 }                            # pop rdi
        elsif ( substr( $here, 0, 2 ) eq "\x48\x89" ) { $i += 3 }                                    # mov rdi/x, rx
        elsif ( ord($here) == 0xFF && ord( substr( $here, 1, 1 ) ) == 0x15 ) { push @checks, $mod; $i += 6 }   # call [rip+disp32]
        elsif ( ord($here) == 0xE8 ) { push @checks, $mod; $i += 5 }                                # call rel32
        elsif ( substr( $here, 0, 2 ) eq "\x0F\x0B" ) { $i += 2 }                                   # ud2
        else { die "unhandled opcode at stub offset $i" }
    }
    return @checks;
}

subtest 'every call in the DragonFly entry stub runs 16-byte aligned' => sub {
    my $platform = Brocken::Katsuro::Platform::parse('x86_64-unknown-dragonfly');
    my $linker   = Brocken::Jenny::Linker::ELF64->new();
    my $stub     = $linker->_build_entry_stub( $platform, {}, 0x1000, 0x4000, 0x4000, 0x4008 );

    is length($stub), 52, 'the stub is 52 bytes with the alignment shuffling';
    is $linker->entry_stub_len($platform), 52, 'entry_stub_len matches';

    my @mods = walk_stack($stub);
    is scalar(@mods), 4, 'init_tls, rtld_call_init, main and exit call sites';
    is \@mods, [ 0, 0, 0, 0 ], 'every call executes with rsp%16 == 0';
};

done_testing;