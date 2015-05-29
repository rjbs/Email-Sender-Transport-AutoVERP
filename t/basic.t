use strict;
use warnings;

use Test::More;

use Email::Simple;
use Email::Sender::Transport::AutoVERP;
use Email::Sender::Transport::Test;

my @results;
my $test = Email::Sender::Transport::Test->new;
my $verp = Email::Sender::Transport::AutoVERP->new({
  transport => $test,

  env_from_generator => sub { my $arg = $_[1]; "$arg->{delivery_id}\@bounce.example.com" },
  result_logger      => sub {
    my ($self, $batch_id, $results) = @_;
    @results = map {; {
      batch_id    => $batch_id,
      delivery_id => $_->{delivery_id},
      env_to      => $_->{to},
      result      => $_->{result}->isa('Email::Sender::Success') ? 'success' : 'fail',
    } } @$results;
  },
});

my $test_email = Email::Simple->create(
  header => [
    From    => 'from@example.com',
    To      => 'to@example.com',
    Subject => 'happy hearts and smiling faces',
  ],
  body => "This message is going to get VERPed old school.\n",
);

$verp->send($test_email, {
  to   => [ qw(to-1@example.com to-2@example.com to-3@example.com) ],
  from => 'does.not.matter@example.net',
});

my @deliveries = $test->deliveries;
is(@deliveries, 3, "we did three distinct deliveries");
is(@results, 3, "...and we logged all three");

my %bounce_addr = map {; $_->{envelope}{from} => 1 } @deliveries;
is(keys %bounce_addr, 3, "...and each had a unique envelope sender");

done_testing;