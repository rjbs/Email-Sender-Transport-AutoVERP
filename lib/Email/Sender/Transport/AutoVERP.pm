package Email::Sender::Transport::AutoVERP;
# ABSTRACT: a transport wrapper that does individual, VERPed, logged sends

use Moo;
extends 'Email::Sender::Transport::Wrapper';

use Params::Util qw(_CODELIKE);
use Data::GUID qw(guid_string);

=head1 SYNOPSIS

  my $low_level_transport = Email::Sender::Transport::SMTP->new;

  my $verp = Email::Sender::Transport::AutoVERP->new({
    transport => $low_level_transport,

    env_from_generator => sub {
      my $arg = $_[1];
      "$arg->{delivery_id}\@bounce.example.com",
    },
    result_logger      => sub {
      my ($self, $batch_id, $results) = @_;

      $db_receipts->insert(
        batch_id    => $batch_id,
        delivery_id => $_->{delivery_id},
        env_to      => $_->{to},
        result      => $_->{result}->isa('Email::Sender::Success') ? 'success' : 'fail',
      ) for @$results;
    },
  });

  $verp->send($email, { to => [ ..., ..., ... ], from => $from });

=head1 OVERVIEW

AutoVERP is a L<wrapper transport|Email::Sender::Transport::Wrapper> that takes
another Email::Sender transport and uses it to break a single delivery into
many deliveries, each with its own envelope sender.  This allows you to track
which recipient bounced, because each recipient has a different bounce path.

You'll have to configure your AutoVERP transport with two or more callbacks,
described below, to provide a way to generate the sender addresses and a way
to log the results of sending.  (You want to log the results so you can later
associate bounces with attempted deliveries.  Putting envelope senders or
delivery ids into a database is one obvious strategy.)

AutoVERP will not be the right solution for every case.  Among other things,
it converts partial successes into total successes, on the theory that as long
as one delivery is made, the rest can be considered successful because the
result logger can log them.  Then, of course, the result logger might fail.

In other words, AutoVERP is less atomic in behavior than its underlying
transport, and this can't be helped in almost any case.  If you need every
SMTP injection to work, you may need to use a job queue or other strategy.

=cut

=attr batch_id_generator

This is an optional callback that will return a unique id to be used to
identify the batch of delivery made for each send.  It is called as a method on
the AutoVERP transport, and is passed a hashref containing:

  email - the email object being sent

By default, this returns a new GUID string on every call.

=cut

has batch_id_generator => (
  is  => 'ro',
  isa => sub { "batch_id_generator is not codelike" unless _CODELIKE($_[0]) },
  default => sub { sub { guid_string() } },
);

=attr delivery_id_generator

This is an optional callback that will return a unique id to be used to
identify a single delivery in the send.  It is called as a method on the
AutoVERP transport, and is passed a hashref containing:

  to       - the address to which this delivery will be made
  email    - the email object being sent
  batch_id - the identifier for the batch

By default, this returns a new GUID string on every call.

=cut

has delivery_id_generator => (
  is  => 'ro',
  isa => sub { "delivery_id_generator is not codelike" unless _CODELIKE($_[0]) },
  default => sub { sub { guid_string() } },
);

=attr env_from_generator

This is a required callback that will return the envelope sender to be used on
a single delivery in the send.  It is called as a method on the AutoVERP
transport, and is passed a hashref containing:

  to       - the address to which this delivery will be made
  email    - the email object being sent
  batch_id - the identifier for the batch
  delivery_id - the delivery id for the delivery

If you've saving delivery information into a database with the delivery
id, a simple implementation could be to return
"DELIVERY-ID@bounce.your-domain.com"

=cut

has env_from_generator => (
  is  => 'ro',
  isa => sub { "env_from_generator is not codelike" unless _CODELIKE($_[0]) },
  required => 1,
);

=attr result_logger

This is a required callback that logs, somehow, the result of all attempted
deliveries. It is called as a method on the AutoVERP transport, and is passed
the batch id and then an arrayref of hashrefs, each of which contains:

  to     - the address to which this delivery was to be made
  from   - the enveloper sender that was used
  result - either an Email::Sender::Success or an Email::Sender::Failure
  delivery_id - the delivery id for the delivery

=cut

has result_logger => (
  is  => 'ro',
  isa => sub { "result_logger is not codelike" unless _CODELIKE($_[0]) },
  required => 1,
);

around send_email => sub {
  my ($orig, $self, $email, $env) = @_;

  my $batch_id_G    = $self->batch_id_generator;
  my $delivery_id_G = $self->delivery_id_generator;
  my $env_from_G    = $self->env_from_generator;

  my $batch_id = $self->$batch_id_G({ email => $email });

  # For some reason, I worry about whether I should bother uniq-ing the list of
  # to addresses.  I'm not going to sweat it for now. -- rjbs, 2015-05-29
  my @results;
  my @failures;

  for my $to (@{ $env->{to} }) {
    my $delivery_id = $self->$delivery_id_G({
      email    => $email,
      to       => $to,
      batch_id => $batch_id,
    });

    my $from = $self->$env_from_G({
      email       => $email,
      to          => $to,
      batch_id    => $batch_id,
      delivery_id => $delivery_id,
    });

    my $result = eval {
      $self->$orig($email, {
        %$env,
        from => $from,
        to   => [ $to ],
      });
    };

    unless ($result) {
      my $error  = $@;
      $result = eval { $error->isa('Email::Sender::Failure') } && $error;
      $result ||= Email::Sender::Failure->new({
        recipients => [ $to ],
        message    => "$error" || "unknown error during sending for $to",
      });

      push @failures, $result;
    }

    push @results, {
      to     => $to,
      from   => $from,
      result => $result,
      delivery_id => $delivery_id,
    };
  }

  if (@failures == @{ $env->{to} }) {
    Email::Sender::Failure::Multi->throw({ failures => @failures });
  }

  my $logged = eval {
    my $result_logger = $self->result_logger;
    $self->$result_logger($batch_id, \@results);
    1;
  };

  $self->handle_result_logging_failure($@, \@results) unless $logged;

  return Email::Sender::Success->new;
};

=method handle_result_logging_failure

  $verp->handle_result_logging_failure($error, \@results);

This method is called when the results can't be logged, and should perform some
kind of sane fallback behavior.  The default behavior will issue a warning.

Making this method throw an exception is not a great idea, as it will prevent
the transport from reporting success, even though the mail has been sent out.

=cut

sub handle_result_logging_failure {
  my ($self, $error, $results) = @_;
  Carp::cluck("error logging results: $error");
}

1;
