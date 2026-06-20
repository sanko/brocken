use v5.42;
use feature qw[class];
no warnings qw[experimental::class];
use Brocken::Katsuro::Platform;

class Brocken::Katsuro::Platform::Wasm : isa(Brocken::Katsuro::Platform) {
    method is_wasm()    {1}
    method is_posix()   { ( $self->os // '' ) =~ /wasi/i || ( $self->env // '' ) =~ /wasi/i }
    method bin_ext()    {'.wasm'}
    method lib_ext()    {'.wasm'}
    method format()     {'wasm'}
    method lib_prefix() {''}
}

=encoding utf-8

=head1 NAME

Brocken::Katsuro::Platform::Wasm - WebAssembly Platform

=head1 DESCRIPTION

Concrete platform class for WebAssembly (WASI). Uses .wasm extensions and the 'wasm' binary format. No library prefix
is used.

=head1 METHODS

=head2 is_wasm

Returns true (1).

=head2 is_posix

Returns true only when the environment is WASI.

=head2 bin_ext

Returns '.wasm'.

=head2 lib_ext

Returns '.wasm'.

=head2 format

Returns 'wasm'.

=head2 lib_prefix

Returns an empty string.

=head1 LICENSE

This software is Copyright (c) 2026 by Sanko Robinson E<lt>sanko@cpan.orgE<gt>.

This is free software, licensed under:

  The Artistic License 2.0 (GPL Compatible)

=head1 AUTHOR

Sanko Robinson <sanko@cpan.org>

=cut

1;
