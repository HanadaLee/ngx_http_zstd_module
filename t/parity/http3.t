#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use Test::Nginx;
use Test::Nginx::HTTP3;
use FindBin;
use lib "$FindBin::Bin/lib";
use Compression;

my $t = Test::Nginx->new()->has(qw/http http_v3 cryptx/);
my $plain = 'multiplexed compression ' x 1024;
$t->write_file('body.txt', $plain);
my $large = 'fair compression response ' x 262144;
$t->write_file('fair.txt', $large);
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    open STDOUT, '>', $t->testdir() . '/openssl.log' or die $!;
    open STDERR, '>&', \*STDOUT or die $!;
    exec 'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-days', '1', '-subj', '/CN=localhost',
        '-keyout', $t->testdir() . '/localhost.key',
        '-out', $t->testdir() . '/localhost.crt';
    die "openssl exec: $!";
}
waitpid($pid, 0);
BAIL_OUT('cannot create test certificate') if $?;
write_config($t, <<'EOF');
%%TEST_GLOBALS%%
daemon off;
error_log %%TESTDIR%%/error.log debug;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    default_type text/plain;
    gzip off;
    gzip_vary on;
    zstd on;
    zstd_types *;
    zstd_min_length 0;

    zstd_buffers 1 64;
    server {
        listen 127.0.0.1:%%PORT_8980_UDP%% quic;
        listen 127.0.0.1:8080;
        ssl_certificate localhost.crt;
        ssl_certificate_key localhost.key;
        ssl_protocols TLSv1.3;
        root %%TESTDIR%%;
        location / {}
        location /ping {
            zstd off;
            return 200 pong;
        }
    }
}
EOF
$t->run();

my $connection = Test::Nginx::HTTP3->new();
my @requests;
for my $encoding (encodings()) {
    my $sid = $connection->new_stream({ headers => [
        { name => ':method', value => 'GET', mode => 4 },
        { name => ':scheme', value => 'https', mode => 4 },
        { name => ':path', value => '/body.txt', mode => 4 },
        { name => ':authority', value => 'localhost', mode => 4 },
        { name => 'accept-encoding', value => $encoding, mode => 4 },
    ]});
    push @requests, [$sid, $encoding];
}
my $frames = $connection->read(all => [
    map { { sid => $_->[0], fin => 1 } } @requests
]);
for my $request (@requests) {
    my ($sid, $encoding) = @$request;
    my ($header) = grep { $_->{type} eq 'HEADERS' && $_->{sid} == $sid } @$frames;
    my $body = join '', map { $_->{data} }
        grep { $_->{type} eq 'DATA' && $_->{sid} == $sid } @$frames;
    is($header->{headers}->{':status'}, 200, "$encoding HTTP/3 status");
    is($header->{headers}->{'content-encoding'}, $encoding,
        "$encoding HTTP/3 encoding");
    is(lc($header->{headers}->{'vary'} // ''), 'accept-encoding', "$encoding HTTP/3 Vary");
    my $response = "HTTP/1.1 200 OK\r\nContent-Encoding: $encoding\r\n\r\n$body";
    is(decoded($t, $response, $plain), $plain,
        "$encoding HTTP/3 multiplexed round trip");
}
check_fairness($t, $connection, $large, 3);
undef $connection;
$t->stop();
like($t->read_file('error.log'), qr/zstd filter yield/,
    'HTTP/3 compression yields');
unlike($t->read_file('error.log'), qr/\[(?:alert|emerg)\]|Sanitizer|runtime error:/,
    'no protocol lifecycle errors');
undef $t;
done_testing();
