# t/triple.t
use v5.38;
use Test2::V0;
use lib qw[lib ../../lib];
use Brocken::Target::Triple;
#
subtest '4-Part Target Triple Parsing' => sub {
    my $t = Brocken::Target::Triple->new( raw_string => 'x86_64-pc-linux-gnu' );
    is $t->arch,         'x86_64', 'parsed architecture';
    is $t->vendor,       'pc',     'parsed vendor';
    is $t->os,           'linux',  'parsed operating system';
    is $t->abi,          'gnu',    'parsed abi environment';
    is $t->format,       'elf',    'inferred binary format is elf';
    is $t->class_arch,   'X64',    'mapped compiler architecture class';
    is $t->class_os,     'Unix',   'mapped compiler operating system class';
    is $t->class_format, 'ELF',    'mapped compiler format class';
};
subtest '3-Part Target Triple Parsing (with Vendor)' => sub {
    my $t = Brocken::Target::Triple->new( raw_string => 'arm64-apple-darwin' );
    is $t->arch,         'arm64',  'parsed architecture';
    is $t->vendor,       'apple',  'recognized known vendor apple';
    is $t->os,           'darwin', 'parsed operating system';
    is $t->format,       'macho',  'inferred binary format is macho';
    is $t->class_arch,   'ARM64',  'mapped compiler architecture class';
    is $t->class_os,     'macOS',  'mapped compiler operating system class';
    is $t->class_format, 'MachO',  'mapped compiler format class';
};
subtest '3-Part Target Triple Parsing (without Vendor)' => sub {
    my $t = Brocken::Target::Triple->new( raw_string => 'x86_64-linux-elf' );
    is $t->arch,   'x86_64',  'parsed architecture';
    is $t->vendor, 'unknown', 'no known vendor matched, defaults to unknown';
    is $t->os,     'linux',   'parsed operating system';
    is $t->abi,    'elf',     'parsed environment';
    is $t->format, 'elf',     'inferred binary format is elf';
};
subtest '2-Part Target Triple Parsing' => sub {
    my $t = Brocken::Target::Triple->new( raw_string => 'riscv64-windows' );
    is $t->arch,         'riscv64', 'parsed architecture';
    is $t->os,           'windows', 'parsed operating system';
    is $t->format,       'pe',      'inferred binary format is pe';
    is $t->class_arch,   'RISC64',  'mapped compiler architecture class';
    is $t->class_os,     'Windows', 'mapped compiler operating system class';
    is $t->class_format, 'PE',      'mapped compiler format class';
};
#
done_testing;
