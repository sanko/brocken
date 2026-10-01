package Brocken::Katsuro v0.0.1 {
    use v5.42;
    use feature qw[class];
    no warnings qw[experimental::class];
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

1;
