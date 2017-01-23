#!/usr/bin/ruby
require 'aws-sdk'
require 'optparse'

##### read command line
script = `basename "#{$0}"`.chomp
@options = {}
OptionParser.new do |opts|
	opts.banner = "#{script} deletes a VPC"
	opts.on("-h", "--help", "show help text") do
		puts opts
		exit
	end
	opts.on("-v", "--verbose", "show more details of setup and takedown steps") do
		@options[:verbose] = true
	end
end.parse!

if(ARGV.size) == 0
	abort "supply the VPC name as a command line argument\n"
end
@vpcname = ARGV[0]

##### find the VPC
waitr = Aws::Waiters::Waiter.new({:delay => 2, :max_attempts => 60})
@client = Aws::EC2::Client.new
resp = @client.describe_vpcs
resp.vpcs.each do |vpc|
	@nameIdx = vpc.tags.find_index{|tt| tt.key == "Name"}
	if vpc.tags[@nameIdx].value == @vpcname
			@vpcid = vpc.vpc_id; 
			@vpctogo = vpc;
			break
	end
end
if @vpcid.nil? 
	abort "VPC named %s not found" %ARGV[0].chomp
end
puts "found VPC named %s with ID %s\nDelete? [N]" % [@vpctogo.tags[@nameIdx].value,  @vpcid]; 
STDIN.gets; 
exit unless $_ =~ /^[yY]/

def loseTheSubnet(subnetId)
	if @options[:verbose]
		puts "delete subnet with id #{subnetId}"
	end
	@client.delete_subnet({
 		subnet_id: subnetId 
	})
	sleep 2
end

##### collect instances to kill
if @options[:verbose]
	puts "terminate any instances"
end
@i_resp = @client.describe_instances
alive = []
@i_resp.reservations.each do |rr| # get a list of active (alive) instances
	rr.instances.each do |ii|
		if ii.state.name != "terminated"
			alive.push( {"id" => ii.instance_id, "subnetid" => ii.network_interfaces[0].subnet_id, "ni" => ii.network_interfaces[0].network_interface_id})
		end
	end
end

##### collect network interfaces
resp = @client.describe_network_interfaces
ni_list=[]
resp[:network_interfaces].each do |ni|
	ni_list.push {ni.network_interface_id, ni.subnet_id}
end
puts "network interfaces:\n"
p ni_list
exit

##### terminate instances
@opc = Aws::OpsWorks::Client.new(region: 'us-west-1')
sbnts = @client.describe_subnets
sbnts.subnets.each do |sbnt|
	if sbnt.vpc_id == @vpcid
		alive.each do |ii|
			if ii["subnetid"] == sbnt.subnet_id
				@client.terminate_instances(instance_ids: [ii["id"]])
				puts "terminating instance id = %s" % ii["id"]
				not_ready = true
				while not_ready do
					my_inst = @client.describe_instances({instance_ids: [ii["id"]]})
#					puts "Check instance id #{ii['id']}"
					if my_inst.reservations[0].instances[0].state.name == "terminated"
						not_ready = false
						puts "instance is now in state #{my_inst.reservations[0].instances[0].state.name}"
					else
#						puts "wait 4 more secs"
						sleep 4
					end
				end
				puts "delete net interface id #{ii['ni']}"
				@client.delete_network_interface({
				  network_interface_id: ii["ni"]
				})
			end
		end
		loseTheSubnet(sbnt.subnet_id)
	end
end

=begin
if @options[:verbose]
	puts "delete subnets"
end
nis = @client.describe_network_interfaces
begin
	sbnts.subnets.each do |sbnt|
		if sbnt.vpc_id == @vpcid
			loseTheSubnet(sbnt.subnet_id)
		end
	end
rescue 'InvalidSubnetIDNotFound'
	puts "subnet id %s not found" 
ensure
	puts "proceeding"
	sbnts = @client.describe_subnets
	sbnts.subnets.each do |sbnt|
		if sbnt.vpc_id == @vpcid
			sid = sbnt.subnet_id
			loseTheSubnet(sid)
			nis.network_interfaces.each do |ni|
				if ni.subnet_id == sid
					@client.delete_network_interface({
					  network_interface_id: ni.network_interface_id 
					})
				end
			end
		end
	end
	sleep 2
end
=end
sleep 2
@client.delete_vpc(:vpc_id => @vpcid)
