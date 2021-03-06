# mt-aws-glacier - Amazon Glacier sync client
# Copyright (C) 2012-2014  Victor Efimov
# http://mt-aws.com (also http://vs-dev.com) vs@vs-dev.com
# License: GPLv3
#
# This file is part of "mt-aws-glacier"
#
#    mt-aws-glacier is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    mt-aws-glacier is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

package App::MtAws::Command::DownloadInventory;

our $VERSION = '1.120';

use strict;
use warnings;
use utf8;
use Carp;
use App::MtAws::Utils;
use App::MtAws::ForkEngine  qw/with_forks fork_engine/;
use App::MtAws::TreeHash;
use App::MtAws::Exceptions;
use App::MtAws::Journal;
use App::MtAws::MetaData;
use App::MtAws::DateTime;
use App::MtAws::Glacier::Inventory::JSON;
use App::MtAws::Glacier::Inventory::CSV;

use App::MtAws::QueueJob::FetchAndDownloadInventory;

sub run
{
	my ($options, $j) = @_;
	with_forks 1, $options, sub {

		my $ft =  App::MtAws::QueueJob::FetchAndDownloadInventory->new();
		my ($R) = fork_engine->{parent_worker}->process_task($ft, undef);
		my $attachmentref = $R->{inventory_raw_ref};
		my $inventory_type = $R->{inventory_type};

		# here we can have response from both JobList or Inventory output..
		# JobList looks like 'response' => '{"JobList":[],"Marker":null}'
		# Inventory retriebal has key 'ArchiveList'
		# TODO: implement it more clear way on level of Job/Tasks object
		croak if -s binaryfilename $options->{'new-journal'}; # TODO: fix race condition between this and opening file
		if ($R && $attachmentref) { # $attachmentref can be SCALAR REF or can be undef
			$j->open_for_write();
			parse_and_write_journal($j, $inventory_type, $attachmentref);
			$j->close_for_write();
		}
	}
}

sub parse_and_write_journal
{
	my ($j, $inventory_type, $attachmentref) = @_;
	my $data = do {
		if ($inventory_type eq INVENTORY_TYPE_JSON) {
			App::MtAws::Glacier::Inventory::JSON->new($$attachmentref)
		} elsif ($inventory_type eq INVENTORY_TYPE_CSV) {
			App::MtAws::Glacier::Inventory::CSV->new($$attachmentref)
		} else {
			confess "unknown inventory type $inventory_type";
		}
	}->get_archives();

	for my $item (@$data) {
		my ($relfilename, $mtime) = App::MtAws::MetaData::meta_decode($item->{ArchiveDescription});
		$relfilename = $item->{ArchiveId} unless defined $relfilename;

		my $creation_time = iso8601_to_epoch($item->{CreationDate}); # TODO: move code out
		#time archive_id size mtime treehash relfilename
		$j->add_entry({
			type => 'CREATED',
			relfilename => $relfilename,
			time => $creation_time,
			archive_id => $item->{ArchiveId},
			size => $item->{Size},
			mtime => $mtime,
			treehash => $item->{SHA256TreeHash},
		});
	}
}

1;

__END__
