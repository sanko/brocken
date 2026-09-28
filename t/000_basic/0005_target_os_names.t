use v5.40;
use lib '../../lib', 'lib';
use Brocken::Target::OS;
use Test2::V0;

# Katsuro spells the DragonFly platform `dragonflybsd` (that is what perl's $^O
# reports) while this module has always used the bare `dragonfly`. Both have to
# resolve, and both have to be recognised as BSD, or 000_init.t dies with
# "Invalid OS: dragonflybsd" on the DragonFly CI leg.
#
# Every construction goes through os_for so a regression is reported as a normal
# failure instead of aborting the file the way the real bug aborted 000_init.t.

{

    package Local::NullOS {
        use overload 'bool' => sub {0}, fallback => 1;
        sub AUTOLOAD   { return }
        sub DESTROY   { }
        our $AUTOLOAD;
    }

    sub os_for {
        my ($name) = @_;
        my $os = eval { Brocken::Target::OS->from_name($name) };
        if ( my $err = $@ ) {
            diag "from_name($name) died: $err";
            return bless {}, 'Local::NullOS';    # false, and every method is undef
        }
        return $os;
    }
}

my @known = qw(linux win64 macos freebsd openbsd netbsd solaris dragonfly dragonflybsd midnightbsd haiku);

for my $name (@known) {
    my $os = os_for($name);
    if ($os) {
        is $os->name, $name, "from_name($name) round-trips";
        ok $os->isa('Brocken::Target::OS'), "from_name($name) isa Brocken::Target::OS";
    }
    else {
        fail "from_name($name) should not die";
    }
}

is ref(os_for('dragonflybsd')), 'Brocken::Target::OS::Dragonfly',
    'dragonflybsd resolves to the Dragonfly subclass';
is ref(os_for('dragonfly')), 'Brocken::Target::OS::Dragonfly',
    'dragonfly resolves to the Dragonfly subclass';

# is_bsd_like is anchored with $, so an unanchored 'dragonfly' alternative would
# silently report false for the longer spelling and break the syscall numbers.
ok os_for('dragonflybsd')->is_bsd_like, 'dragonflybsd is bsd_like';
ok os_for('dragonfly')->is_bsd_like,    'dragonfly is bsd_like';
ok os_for('netbsd')->is_bsd_like,        'netbsd is bsd_like';
ok !os_for('linux')->is_bsd_like,        'linux is not bsd_like';
ok !os_for('win64')->is_bsd_like,        'win64 is not bsd_like';

# DragonFly is BSD: write(4) and exit(1) on all three supported architectures.
for my $arch (qw(x64 arm64 riscv64)) {
    is os_for('dragonflybsd')->syscall_write($arch), 4, "dragonflybsd write is 4 on $arch";
    is os_for('dragonflybsd')->syscall_exit($arch),  1, "dragonflybsd exit is 1 on $arch";
}

# Unknown names must still be rejected rather than silently accepted.
for my $bad (qw(plan9 aix dragon dragnfly linux2)) {
    ok !os_for($bad), "from_name($bad) is rejected";
}

ok os_for('dragonflybsd')->is_posix, 'dragonflybsd is posix';
ok !os_for('win64')->is_posix,        'win64 is not posix';
is os_for('win64')->exe_ext, '.exe', 'win64 exe ext';
is os_for('dragonflybsd')->exe_ext, '', 'dragonflybsd exe ext';
is os_for('dragonflybsd')->lib_ext, '.so', 'dragonflybsd lib ext';

# detect_host used to compare $^O eq 'dragonfly', but perl reports the
# DragonFly kernel as 'dragonflybsd', so it silently fell through to 'linux'.
{
    no warnings 'once';
    local $^O = 'dragonflybsd';
    is Brocken::Target::OS->detect_host->name, 'dragonfly', 'detect_host maps dragonflybsd';
    local $^O = 'dragonfly';
    is Brocken::Target::OS->detect_host->name, 'dragonfly', 'detect_host maps dragonfly';
    local $^O = 'netbsd';
    is Brocken::Target::OS->detect_host->name, 'netbsd', 'detect_host maps netbsd';
    local $^O = 'linux';
    is Brocken::Target::OS->detect_host->name, 'linux', 'detect_host maps linux';
}

done_testing;
