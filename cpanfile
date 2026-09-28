on configure => sub {
    requires 'Module::Build::Tiny', '0.034';

    #~ Must track the strictest `use vX.Y` in lib/. Ten modules (including
    #~ Brocken.pm itself) declare v5.42, so anything lower installs the
    #~ dependencies cleanly and then dies on the first compile.
    requires 'perl',                'v5.42.0';
};
