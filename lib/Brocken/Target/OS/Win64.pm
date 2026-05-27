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
        return { ExitProcess => 0x3000, ExitThread => 0x3008, GetStdHandle => 0x3010, WriteFile => 0x3018, CreateThread => 0x3020, Sleep => 0x3028, WaitForSingleObject => 0x3030, }->{$name};
    }
}
1;
