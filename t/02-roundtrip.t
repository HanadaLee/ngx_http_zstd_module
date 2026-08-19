use strict;
use warnings;

use FindBin;
use Test::More;

my $nginx = $ENV{'TEST_NGINX_BINARY'};
if (!defined $nginx || !-x $nginx) {
    chomp($nginx = qx{command -v nginx 2>/dev/null});
}

if (!defined $nginx || !-x $nginx) {
    plan skip_all => 'nginx binary is not available';
}

chomp(my $python = qx{command -v python3 2>/dev/null});
if (!$python) {
    plan skip_all => 'python3 is not available';
}

local $ENV{'PYTHONDONTWRITEBYTECODE'} = 1;

my @command = (
    $python,
    "$FindBin::Bin/lib/roundtrip.py",
    '--nginx-binary', $nginx,
);

my $status = system @command;
is($status >> 8, 0, 'zstd responses round-trip byte-for-byte');

done_testing();
