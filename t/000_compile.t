use v5.40;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use lib 'lib', '../lib', 'blib/lib', '../blib/lib';
use Brocken;
#
ok $Brocken::VERSION, 'Brocken::VERSION';
#
done_testing;
