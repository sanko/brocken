use v5.40;
use feature 'class';
no warnings 'portable', 'experimental::class';

class Brocken::Target::OS::Win64 : isa(Brocken::Target::OS) {
    ADJUST {
        die "OS name mismatch" unless $self->name eq 'win64';
    }
    method text_rva () { return 0x1000 }
    method data_rva () { return 0x2000 }

    method symbol_rva ($name) {
        return { ExitProcess => 0x3000, GetStdHandle => 0x3008, WriteFile => 0x3010, CreateThread => 0x3018, Sleep => 0x3020, }->{$name};
    }
}
1;
