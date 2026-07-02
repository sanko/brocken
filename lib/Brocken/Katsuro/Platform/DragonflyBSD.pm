use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform::BSD;

class Brocken::Katsuro::Platform::DragonflyBSD : isa(Brocken::Katsuro::Platform::BSD) {
    method is_dragonflybsd()         {1}
    method libc_name()               {'libc.so.8'}
    method libpthread_name()         {'libthread_xu.so.2'}
    method interpreter()             {'/libexec/ld-elf.so.2'}
    method exit_name()               {'exit'}
    method needs_sched_setaffinity() {1}
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::DragonflyBSD - DragonFly BSD Platform

=head1 DESCRIPTION

Concrete platform class for DragonFly BSD. Inherits from B<BSD>.

=head1 METHODS

=head2 is_dragonflybsd

Returns true (1). Overrides the default (0) from L<Brocken::Katsuro::Platform>.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
