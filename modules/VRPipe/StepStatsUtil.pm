use VRPipe::Base;

class VRPipe::StepStatsUtil {
    use POSIX;
    
    our %means;
    our %percentiles;
    
    has 'step' => (is => 'rw',
                   isa => 'VRPipe::Step',
                   required => 1);
    
    method _percentile (Str $column! where { $_ eq 'memory' || $_ eq 'time' }, Int $percent! where { $_ > 0 && $_ < 100 }, VRPipe::PipelineSetup $pipelinesetup?) {
        # did we already work this out in the past hour?
        my $step = $self->step;
        my $time = time();
        my $store_key = $step->id.$column.$percent. ($pipelinesetup ? $pipelinesetup->id : 0);
        my $p_data = $percentiles{$store_key};
        if ($p_data && $p_data->[0] + 3600 > $time) {
            return ($p_data->[1], $p_data->[2]);
        }
        
        my $schema = $step->result_source->schema;
        my @search_args = (step => $step->id, $pipelinesetup ? (pipelinesetup => $pipelinesetup->id) : ());
        my ($count, $percentile) = (0, 0);
        $count = $schema->resultset('StepStats')->search({ @search_args })->count;
        if ($count) {
            my $rs = $schema->resultset('StepStats')->search({ @search_args }, { order_by => { -desc => [$column] }, rows => 1, offset => sprintf("%0.0f", ($count / 100) * (100 - $percent)) });
            $percentile = $rs->get_column($column)->next;
        }
        
        $percentiles{$store_key} = [$time, $count, $percentile] if $count > 500;
        return ($count, $percentile);
    }
    method percentile_seconds (Int :$percent!, VRPipe::PipelineSetup :$pipelinesetup?) {
        return $self->_percentile('time', $percent, $pipelinesetup ? ($pipelinesetup) : ());
    }
    method percentile_memory (Int :$percent!, VRPipe::PipelineSetup :$pipelinesetup?) {
        return $self->_percentile('memory', $percent, $pipelinesetup ? ($pipelinesetup) : ());
    }
    
    method _mean (Str $column! where { $_ eq 'memory' || $_ eq 'time' }, VRPipe::PipelineSetup $pipelinesetup?) {
        # did we already work this out in the past hour?
        my $step = $self->step;
        my $time = time();
        my $store_key = $step->id.$column. ($pipelinesetup ? $pipelinesetup->id : 0);
        my $mean_data = $means{$store_key};
        if ($mean_data && $mean_data->[0] + 3600 > $time) {
            return ($mean_data->[1], $mean_data->[2], $mean_data->[3]);
        }
        
        # get the mean and sd using little memory
        my ($count, $mean, $sd) = (0, 0, 0);
        my $schema = $step->result_source->schema;
        my $rs = $schema->resultset('StepStats')->search({ step => $step->id, $pipelinesetup ? (pipelinesetup => $pipelinesetup->id) : () });
        my $rs_column = $rs->get_column($column);
        while (my $stat = $rs_column->next) { # using $rs_column instead of $rs is >60x faster with 100k+ rows
            $count++;
            if ($count == 1) {
                $mean = $stat;
                $sd = 0;
            }
            else {
                my $old_mean = $mean;
                $mean += ($stat - $old_mean) / $count;
                $sd += ($stat - $old_mean) * ($stat - $mean);
            }
        }
        
        if ($count) {
            $mean = sprintf("%0.0f", $mean);
            $sd = sprintf("%0.0f", sqrt($sd / $count));
        }
        
        $means{$store_key} = [$time, $count, $mean, $sd] if $count > 500;
        return ($count, $mean, $sd);
    }
    method mean_seconds (VRPipe::PipelineSetup :$pipelinesetup?) {
        return $self->_mean('time', $pipelinesetup ? ($pipelinesetup) : ());
    }
    method mean_memory (VRPipe::PipelineSetup :$pipelinesetup?) {
        return $self->_mean('memory', $pipelinesetup ? ($pipelinesetup) : ());
    }
    
    method _recommended (Str $method! where { $_ eq 'memory' || $_ eq 'time' }, VRPipe::PipelineSetup $pipelinesetup?) {
        # if we've seen enough previous results, recommend 95th percentile
        # rounded up to nearest 100
        my ($count, $percentile) = $self->_percentile($method, 95, $pipelinesetup ? ($pipelinesetup) : ());
        if ($count >= 3) {
            if ($percentile % 100) {
                return (1 + int($percentile/100)) * 100;
            }
            else {
                return $percentile;
            }
        }
        return;
    }
    method recommended_memory (VRPipe::PipelineSetup :$pipelinesetup?) {
        my $mem = $self->_recommended('memory', $pipelinesetup ? ($pipelinesetup) : ()) || return;
        
        # recommend at least 100MB though
        if ($mem < 100) {
            $mem = 100;
        }
        return $mem;
    }
    method recommended_time (VRPipe::PipelineSetup :$pipelinesetup?) {
        my $seconds = $self->_recommended('time', $pipelinesetup ? ($pipelinesetup) : ()) || return;
        
        # convert to hrs, rounded up
        return ceil($seconds / 60 / 60);
    }
}

1;