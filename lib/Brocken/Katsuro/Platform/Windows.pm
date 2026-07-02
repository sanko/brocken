use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::Windows : isa(Brocken::Katsuro::Platform) {
    method is_windows() {1}
    method is_posix()   {0}
    method bin_ext()    {'.exe'}
    method lib_ext()    {'.dll'}
    method format()     {'pe'}
    method lib_prefix() {''}

    method static_lib_ext() {
        return '.a' if $self->env eq 'gnu';
        return '.lib';
    }

    method shared_lib_name( $name, $version = undef ) {
        return $name . $self->lib_ext if !defined $version;
        return $name . '-' . $version . $self->lib_ext;
    }
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::Windows - Windows Platform

=head1 DESCRIPTION

Concrete platform class for Windows. Uses PE (Portable Executable) format, .exe binaries, .dll shared libraries, and
.lib static libraries. Not POSIX-compliant. Library prefix is empty (e.g., "kernel32.dll").

=head1 METHODS

=head2 is_windows

Returns true (1).

=head2 is_posix

Returns false (0).

=head2 bin_ext

Returns '.exe'.

=head2 lib_ext

Returns '.dll'.

=head2 format

Returns 'pe'.

=head2 lib_prefix

Returns an empty string.

=head2 static_lib_ext

Returns '.a' for GNU environments, '.lib' otherwise.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
