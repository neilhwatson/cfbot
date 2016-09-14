# cfbot

[![Build Status](https://travis-ci.org/neilhwatson/cfbot.svg?branch=master)](https://travis-ci.org/neilhwatson/cfbot)

An IRC bot for CFEngine channels that allows users to query if for answers.

## Requirements

Multiple Perl modules all shown in cfbot.pl and daemon.pl.

## To use

Query the bot for EFL with !cfbot EFL and the definition for EFL will appear in the channel.

## To contribute

### Adding the knowledge base

1. Edit the files topics.yml or words\_of\_wisdom, honouring the existing format.
1. Submit a pull request.
1. Your pull request will be test by TravisCI. If it fails you'll have to resubmit. I recommend you test your code with 'prove'.
