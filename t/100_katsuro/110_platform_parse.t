use v5.42;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../../lib', '../lib';
use Brocken::Katsuro;
no warnings qw[experimental::class experimental::builtin portable];
use feature qw[class];

subtest 'normalize triple' => sub {
    is Brocken::Katsuro::Platform::normalize_triple('x86_64'), 'x86_64-unknown-unknown-unknown', 'single part';
    is Brocken::Katsuro::Platform::normalize_triple('x86_64-linux-gnu'), 'x86_64-pc-linux-gnu', 'arch-os-env';
    is Brocken::Katsuro::Platform::normalize_triple('x86_64-pc-linux-gnu'), 'x86_64-pc-linux-gnu', 'full triple';
    is Brocken::Katsuro::Platform::normalize_triple('aarch64-apple-darwin'), 'aarch64-apple-darwin-macho', 'apple triple';
    is Brocken::Katsuro::Platform::normalize_triple('x86_64-w64-mingw32'), 'x86_64-pc-windows-gnu', 'mingw triple';
    is Brocken::Katsuro::Platform::normalize_triple('arm64'), 'aarch64-unknown-unknown-unknown', 'arm64 -> aarch64';
    is Brocken::Katsuro::Platform::normalize_triple('amd64'), 'x86_64-unknown-unknown-unknown', 'amd64 -> x86_64';
    is Brocken::Katsuro::Platform::normalize_triple('i686'), 'i386-unknown-unknown-unknown', 'i686 -> i386';
    is Brocken::Katsuro::Platform::normalize_triple('arm64_32'), 'aarch64-unknown-unknown-unknown', 'arm64_32 -> aarch64';
    is Brocken::Katsuro::Platform::normalize_triple('riscv64gc'), 'riscv64-unknown-unknown-unknown', 'riscv64gc -> riscv64';
};

subtest 'parse triples' => sub {
    my @tests = (
        [ 'x86_64-unknown-linux-gnu',            'x86_64', 'unknown', 'linux',    'gnu'      ],
        [ 'aarch64-unknown-linux-gnu',           'aarch64', 'unknown','linux',    'gnu'      ],
        [ 'x86_64-pc-windows-msvc',              'x86_64',  'pc',     'windows',  'msvc'     ],
        [ 'x86_64-pc-windows-gnu',               'x86_64',  'pc',     'windows',  'gnu'      ],
        [ 'aarch64-pc-windows-msvc',             'aarch64', 'pc',     'windows',  'msvc'     ],
        [ 'aarch64-pc-windows-gnullvm',          'aarch64', 'pc',     'windows',  'gnullvm'  ],
        [ 'aarch64-apple-darwin',                'aarch64', 'apple',  'darwin',   'macho'    ],
        [ 'aarch64-apple-ios',                   'aarch64', 'apple',  'ios',      'unknown'  ],
        [ 'x86_64-unknown-freebsd',              'x86_64',  'unknown','freebsd',  'unknown'  ],
        [ 'x86_64-unknown-netbsd',               'x86_64',  'unknown','netbsd',   'unknown'  ],
        [ 'x86_64-unknown-openbsd',              'x86_64',  'unknown','openbsd',  'unknown'  ],
        [ 'x86_64-pc-freebsd14.1',               'x86_64',  'pc',     'freebsd',  'unknown'  ],
        [ 'aarch64-pc-freebsd14.1',              'aarch64', 'pc',     'freebsd',  'unknown'  ],
        [ 'aarch64-unknown-netbsd',              'aarch64', 'unknown','netbsd',   'unknown'  ],
        [ 'wasm32-unknown-unknown',              'wasm32',  'unknown','unknown',  'unknown'  ],
        [ 'wasm32-wasi',                         'wasm32',  'unknown','wasi',     'unknown'  ],
        [ 'x86_64-pc-dragonflybsd',              'x86_64',  'pc',     'dragonflybsd','unknown'],
        [ 'x86_64-unknown-freebsd13.4',          'x86_64',  'unknown','freebsd',  'unknown'  ],
        [ 'i86pc-unknown-solaris',               'x86_64',  'unknown','solaris',   'unknown'  ],
        [ 'riscv64gc-unknown-linux-gnu',         'riscv64', 'unknown','linux',    'gnu'      ],
        [ 'arm64_32-apple-watchos',              'aarch64', 'apple',  'watchos',  'unknown'  ],
    );
    for my $t (@tests) {
        my ( $raw, $arch, $vendor, $os, $env ) = $t->@*;
        my $p = Brocken::Katsuro::Platform::parse($raw);
        is $p->arch,   $arch,   "$raw: arch = $arch";
        is $p->vendor, $vendor, "$raw: vendor = $vendor";
        is $p->os,     $os,     "$raw: os = $os";
        is $p->env,    $env,    "$raw: env = $env";
    }
};

subtest 'os_version' => sub {
    my $p1 = Brocken::Katsuro::Platform::parse('x86_64-unknown-freebsd');
    is $p1->os,         'freebsd', 'freebsd no version: os';
    is $p1->os_version, undef,     'freebsd no version: os_version undef';

    my $p2 = Brocken::Katsuro::Platform::parse('x86_64-pc-freebsd14.1');
    is $p2->os,         'freebsd', 'freebsd 14.1: os';
    is $p2->os_version, '14.1',    'freebsd 14.1: os_version';

    my $p3 = Brocken::Katsuro::Platform::parse('x86_64-unknown-freebsd13.4');
    is $p3->os,         'freebsd',  'freebsd 13.4: os';
    is $p3->os_version, '13.4',     'freebsd 13.4: os_version';

    my $p4 = Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu');
    is $p4->os,         'linux', 'linux: os';
    is $p4->os_version, undef,   'linux: os_version undef';
};

subtest 'platform properties' => sub {
    my $linux   = Brocken::Katsuro::Platform::parse('x86_64-unknown-linux-gnu');
    my $windows = Brocken::Katsuro::Platform::parse('x86_64-pc-windows-msvc');
    my $macos   = Brocken::Katsuro::Platform::parse('aarch64-apple-darwin');
    my $wasm    = Brocken::Katsuro::Platform::parse('wasm32-wasi');

    ok $linux->is_posix,   'linux is posix';
    ok !$windows->is_posix, 'windows is not posix';
    ok $linux->is_linux,   'linux is_linux';
    ok $windows->is_windows, 'windows is_windows';
    ok $macos->is_macos,   'macos is_macos';
    ok $wasm->is_wasm,     'wasm is_wasm';

    is $linux->bin_ext,   '',       'linux bin_ext';
    is $windows->bin_ext, '.exe',   'windows bin_ext';
    is $macos->bin_ext,   '',       'macos bin_ext';
    is $wasm->bin_ext,    '.wasm',  'wasm bin_ext';

    is $linux->lib_ext,   '.so',    'linux lib_ext';
    is $windows->lib_ext, '.dll',   'windows lib_ext';
    is $macos->lib_ext,   '.dylib', 'macos lib_ext';
    is $wasm->lib_ext,    '.wasm',  'wasm lib_ext';

    is $linux->format,   'elf',   'linux format';
    is $windows->format, 'pe',    'windows format';
    is $macos->format,   'macho', 'macos format';
    is $wasm->format,    'wasm',  'wasm format';

    ok !$linux->is_bsd, 'linux is not bsd';
    ok !$macos->is_bsd, 'macos is not bsd (darwin is mach-based)';
};

done_testing;
