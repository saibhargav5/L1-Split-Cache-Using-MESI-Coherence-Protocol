module SplitL1Cache ;
	parameter Sets      		= 2**14; 		// sets (16K)
	parameter AddressBits    	= 32;	 		// Address bits (32-bit processor)
	parameter DataWay      	   	= 8;	 		// Data 8 Way Cache
	parameter InstWay      	   	= 4;	 		// Instruction 4 Way Cache
	parameter ByteLines 		= 64;	 		// Cache lines (64-byte)
	
	localparam IndexBits 		= $clog2(Sets); 	 			// Index bits
	localparam ByteOffset 		= $clog2(ByteLines);		 		// byte select bits
	localparam TagBits 		= (AddressBits)-(IndexBits+ByteOffset); 	// Tag bits
	localparam DataWay_bits		= $clog2(DataWay);				// Data way select bits 
	localparam InstWay_bits		= $clog2(InstWay);   				// Instruction way select bits

	
	logic	Mode;					// Mode select
	logic 	Hit;					// Indicates a Hit or a Miss 
	logic	NOT_Valid;				// Indicates when invalid line is present
	logic 	[3:0] n;				// Instruction code from trace file
	logic 	[TagBits - 1 :0] Tag;			// Tag
	logic 	[ByteOffset - 1 :0] Byte;		// Byte select
	logic 	[IndexBits - 1	:0] Index;		// Index
	logic 	[AddressBits - 1 :0] Address;	        // Address
	
	bit 	[DataWay_bits - 1 :0]	Data_ways;		 	// Data ways
	bit 	[InstWay_bits - 1 :0]	Instruction_ways;		// Instruction ways
	bit 	Flag;
	
	int		TRACE;					// file descriptor
	int		temp_display;	
	
	int Data_CacheHITcount  	= 0; 				// No. of Data Cache Hits
	int Data_CacheMISScount 	= 0; 				// No. of Cache Misses
	int Data_CacheREADcount 	= 0; 				// No. of Cache reads
	int Data_CacheWRITEcount 	= 0; 				// No. of Cache writes

	int Inst_CacheHITcount  	= 0; 		// No. of Instruction Cache Hits
	int Inst_CacheMISScount 	= 0; 		// No. of Instruction Cache Misses
	int Inst_CacheREADcount 	= 0; 		// No. of Instruction Cache reads
	
	real Data_CacheHitRatio;			// Data Cache Hit ratio
	real Inst_CacheHITRatio; 			// Instruction Cache Hit Ratio

	longint CacheIterations = 0;			// No.of Cache accesses
	
	// typedef for MESI states
	typedef enum logic [1:0]{       				
				Invalid 	= 2'b00,
				Shared 		= 2'b01, 
				Modified 	= 2'b10, 
				Exclusive 	= 2'b11	
				} mesi;

	// typedef for L1 Data Cache			
	typedef struct packed {							
				mesi MESI_bits;
				bit [DataWay_bits-1:0]	LRU_bits;
				bit [TagBits	-1:0] 	TagBits;			 
				} CacheLine_DATA;
CacheLine_DATA [Sets-1:0] [DataWay-1:0] L1_DATA_Cache; 

	// typedef for L1 Instruction Cache
	typedef struct packed {							
				mesi MESI_bits;
				bit [InstWay_bits-1:0]	LRU_bits;
				bit [TagBits	-1:0] 	TagBits;     
				} CacheLine_INSTRUCTION;
CacheLine_INSTRUCTION [Sets-1:0][InstWay-1:0] L1_INSTRUCTION_Cache; 


//-----------------------------------------------------------------------------------------------------------------------------------------
//  Read instructions from Trace File 
//-----------------------------------------------------------------------------------------------------------------------------------------

initial							
begin
	ClearCache();
    TRACE = $fopen("cc1.din" , "r");
   	if ($test$plusargs("USER_MODE")) 
			Mode=0;
    	else
    		Mode=1;
	while (!$feof(TRACE))				//when end of the trace file is not reached
	begin
        temp_display = $fscanf(TRACE, "%h %h\n",n,Address);
        {Tag,Index,Byte} = Address;
    
		case (n) inside
			4'd0:	ReadFromL1DataCache(Tag,Index,Mode);   		
			4'd1:	WritetoL1DataCache (Tag,Index,Mode);
			4'd2: 	InstructionFetch	   (Tag,Index,Mode);
			4'd3:	SendInvalidateCommandFromL2Cache(Tag,Index,Mode);   
			4'd4:	DataRequestFromL2Cache (Tag,Index,Mode);
			4'd8:	ClearCache();
			4'd9:	Print_CacheContents_MESIstates();
		endcase			
	end
	$fclose(TRACE);
	Data_CacheHitRatio = (real'(Data_CacheHITcount)/(real'(Data_CacheHITcount) + real'(Data_CacheMISScount))) * 100.00;
	Inst_CacheHITRatio 	= (real'(Inst_CacheHITcount) /(real'(Inst_CacheHITcount)  + real'(Inst_CacheMISScount))) *100.00;

	$display("************************************************** DATA  CACHE  STATSITICS *************************************************************");
	$display("Data Cache Reads     = %d\nData Cache Writes    = %d\nData Cache Hits      = %d \nData Cache Misses    = %d \nData Cache Hit Ratio = %f\n", Data_CacheREADcount, Data_CacheWRITEcount, Data_CacheHITcount, Data_CacheMISScount, Data_CacheHitRatio);
	
	$display("*********************************************** INSTRUCTION  CACHE STATSITICS ***************************************************************");
	$display("Instruction Cache Reads     = %d \nInstruction Cache Misses    = %d \nInstruction Cache Hits      = %d \nInstruction Cache Hit Ratio =  %f \n",Inst_CacheREADcount, Inst_CacheMISScount, Inst_CacheHITcount, Inst_CacheHITRatio);
	$finish;													
end

//-----------------------------------------------------------------------------------------------------------------------------------------
//Read Data From L1 Cache
//-----------------------------------------------------------------------------------------------------------------------------------------

task ReadFromL1DataCache ( logic [TagBits-1 :0] Tag, logic [IndexBits-1:0] Index, logic Mode); 
	
	Data_CacheREADcount++ ;
	Data_Address_Valid (Index,Tag,Hit,Data_ways);
	
	if (Hit == 1)
	begin
		Data_CacheHITcount++ ;
		UpdateLRUBits_data(Index, Data_ways );
		L1_DATA_Cache[Index][Data_ways].MESI_bits = (L1_DATA_Cache[Index][Data_ways].MESI_bits == Exclusive) ? Shared : L1_DATA_Cache[Index][Data_ways].MESI_bits ;		
	end
	else
	begin
		Data_CacheMISScount++ ;
		NOT_Valid = 0;
		If_Invalid_Data (Index , NOT_Valid , Data_ways );
		
		if (NOT_Valid)
		begin
			Data_Allocate_CacheLine(Index,Tag, Data_ways);
			UpdateLRUBits_data(Index, Data_ways );
			L1_DATA_Cache[Index][Data_ways].MESI_bits = Exclusive;   
			
			if (Mode==1)
				$display("Read from L2 address       %d'h%h" ,AddressBits,Address);
		end
		else    
		begin
			Eviction_Data(Index, Data_ways);
			Data_Allocate_CacheLine(Index, Tag, Data_ways);
			UpdateLRUBits_data(Index, Data_ways );
			L1_DATA_Cache[Index][Data_ways].MESI_bits = Exclusive;  
			
			if (Mode==1)
				$display("Read from L2 address       %d'h%h" ,AddressBits,Address);
		end
	end	
endtask

//---------------------------------------------------------------------------------------------------------------------------------------
// Write Data to L1 Data Cache
//---------------------------------------------------------------------------------------------------------------------------------------

task WritetoL1DataCache ( logic [TagBits -1 :0] Tag, logic [IndexBits-1:0] Index, logic Mode);
	
	Data_CacheWRITEcount++ ;
	Data_Address_Valid (Index, Tag, Hit, Data_ways);
	
	if (Hit == 1)
	begin
		Data_CacheHITcount++ ;
		UpdateLRUBits_data(Index, Data_ways );	
		if (L1_DATA_Cache[Index][Data_ways].MESI_bits == Shared)
		begin
			L1_DATA_Cache[Index][Data_ways].MESI_bits = Exclusive;
			if(Mode==1) $display("Write to L2 address        %d'h%h" ,AddressBits,Address);
		end
		else if(L1_DATA_Cache[Index][Data_ways].MESI_bits == Exclusive)
			L1_DATA_Cache[Index][Data_ways].MESI_bits = Modified;
	end
	else
	begin
		Data_CacheMISScount++ ;
		If_Invalid_Data(Index , NOT_Valid , Data_ways );
	
		if (NOT_Valid)
		begin
			Data_Allocate_CacheLine(Index,Tag, Data_ways);
			UpdateLRUBits_data(Index, Data_ways );
			L1_DATA_Cache[Index][Data_ways].MESI_bits = Exclusive;
			if (Mode==1)
				$display("Read for ownership from L2 %d'h%h\nWrite to L2 address        %d'h%h ",AddressBits,Address,AddressBits,Address);
		end
		else
		begin
			Eviction_Data(Index, Data_ways);
			Data_Allocate_CacheLine(Index, Tag, Data_ways);
			UpdateLRUBits_data(Index, Data_ways );
			L1_DATA_Cache[Index][Data_ways].MESI_bits = Modified;  
			if (Mode==1) 
				$display("Read for ownership from L2 %d'h%h",AddressBits,Address);
		end
	end	
endtask

//------------------------------------------------------------------------------------------------------------------------------------------
//Instruction Fetch
//------------------------------------------------------------------------------------------------------------------------------------------

task InstructionFetch ( logic [TagBits -1 :0] Tag, logic [IndexBits-1:0] Index, logic Mode);
	
	Inst_CacheREADcount++ ;
	Inst_Address_Valid (Index, Tag, Hit, Instruction_ways);
	
	if (Hit == 1)
	begin
		Inst_CacheHITcount++ ;
		UpdateLRUBits_ins(Index, Instruction_ways );
		L1_INSTRUCTION_Cache[Index][Instruction_ways].MESI_bits = (L1_INSTRUCTION_Cache[Index][Instruction_ways].MESI_bits == Exclusive) ? Shared : L1_INSTRUCTION_Cache[Index][Instruction_ways].MESI_bits	;
	end
	else
	begin
		Inst_CacheMISScount++ ;
		If_Invalid_Inst(Index ,  NOT_Valid , Instruction_ways );
		
		if (NOT_Valid)
		begin
			Inst_Allocate_Line(Index,Tag, Instruction_ways);
			UpdateLRUBits_ins(Index, Instruction_ways );
			L1_INSTRUCTION_Cache[Index][Instruction_ways].MESI_bits = Exclusive; 
			if (Mode==1)
				$display("Read from L2 address       %d'h%h" ,AddressBits,Address);
		end
		else
		begin
			Eviction_Inst(Index, Instruction_ways);
			Inst_Allocate_Line(Index, Tag, Instruction_ways);
			UpdateLRUBits_ins(Index,  Instruction_ways );
			L1_INSTRUCTION_Cache[Index][Instruction_ways].MESI_bits = Exclusive;         
			if (Mode==1)
				$display("Read from L2 address       %d'h%h" ,AddressBits,Address);
		end
	end
endtask

//------------------------------------------------------------------------------------------------------------------------------------------
//Data Request From L2 Cache
//------------------------------------------------------------------------------------------------------------------------------------------

task DataRequestFromL2Cache ( logic [TagBits -1 :0] Tag, logic [IndexBits-1:0] Index, logic Mode); // Data Request from L2 Cache
	
	Data_Address_Valid (Index, Tag, Hit, Data_ways);
	if (Hit == 1)
		case (L1_DATA_Cache[Index][Data_ways].MESI_bits) inside
		
			Exclusive:	L1_DATA_Cache[Index][Data_ways].MESI_bits = Shared;
			Modified :	begin
						L1_DATA_Cache[Index][Data_ways].MESI_bits = Invalid;
						if (Mode==1)
							$display("Return data to L2 address  %d'h%h" ,AddressBits,Address);
					end
		endcase
endtask   

//------------------------------------------------------------------------------------------------------------------------------------------
//Address Valid task
//------------------------------------------------------------------------------------------------------------------------------------------

task automatic Data_Address_Valid (logic [IndexBits-1 :0] iIndex, logic [TagBits -1 :0] iTag, output logic Hit , ref bit [DataWay_bits-1:0] Data_ways ); 
	Hit = 0;

	for (int j = 0;  j < DataWay ; j++)
		if (L1_DATA_Cache[iIndex][j].MESI_bits != Invalid) 	
			if (L1_DATA_Cache[iIndex][j].TagBits == iTag)
			begin 
				Data_ways = j;
				Hit = 1; 
				return;
			end			
endtask

task automatic Inst_Address_Valid (logic [IndexBits-1 :0] iIndex, logic [TagBits -1 :0] iTag, output logic Hit , ref bit [InstWay_bits-1:0] Instruction_ways);
	Hit = 0;

	for (int j = 0;  j < InstWay ; j++)
		if (L1_INSTRUCTION_Cache[iIndex][j].MESI_bits != Invalid) 
			if (L1_INSTRUCTION_Cache[iIndex][j].TagBits == iTag)
			begin 
				Instruction_ways = j;
				Hit = 1; 
				return;
			end
endtask

//-------------------------------------------------------------------------------------------------------------------------------------------------
//Check for Invalid states
//-------------------------------------------------------------------------------------------------------------------------------------------------

task automatic If_Invalid_Data (logic [IndexBits-1:0] iIndex, output logic Invalid, ref bit [DataWay_bits-1:0] Data_ways); // Find invalid Cache line in DATA CACHE
	NOT_Valid =  0;
	for (int i =0; i< DataWay; i++ )
	begin
		if (L1_DATA_Cache[iIndex][i].MESI_bits == Invalid)
		begin
			Data_ways = i;
			NOT_Valid = 1;
			return;
		end
	end
endtask

task automatic If_Invalid_Inst (logic [IndexBits - 1:0] iIndex, output logic NOT_Valid, ref bit [InstWay_bits-1:0] Instruction_ways); // Find invalid Cache line in INSTRUCTION CACHE
	NOT_Valid =  0;
	for(int i =0; i< InstWay; i++ )
		if (L1_INSTRUCTION_Cache[iIndex][i].MESI_bits == Invalid)
		begin
			Instruction_ways = i;
			NOT_Valid = 1;
			return;
		end
endtask

//------------------------------------------------------------------------------------------------------------------------------------------
//Send Invalidate Command From L2 Cache
//------------------------------------------------------------------------------------------------------------------------------------------

task SendInvalidateCommandFromL2Cache ( logic [TagBits -1 :0] Tag, logic [IndexBits-1:0] Index, logic Mode);
	
	Data_Address_Valid (Index, Tag, Hit, Data_ways);
	if (Hit == 1)
	begin
	 	if( Mode==1 && (L1_DATA_Cache[Index][Data_ways].MESI_bits == Modified)) 
			$display("Write to L2 address        %d'h%h" ,AddressBits,Address);
		L1_DATA_Cache[Index][Data_ways].MESI_bits = Invalid;
	end
endtask

//-------------------------------------------------------------------------------------------------------------------------------------------------
//Cache line Allocation
//-------------------------------------------------------------------------------------------------------------------------------------------------

task automatic Data_Allocate_CacheLine (logic [IndexBits -1:0] iIndex, logic [TagBits -1 :0] iTag, ref bit [DataWay_bits-1:0] Data_ways); // Allocacte Cache Line in DATA CACHE
	L1_DATA_Cache[iIndex][Data_ways].TagBits = iTag;
	UpdateLRUBits_data(iIndex, Data_ways);		
endtask

task automatic Inst_Allocate_Line (logic [IndexBits -1 :0] iIndex, logic [TagBits -1 :0] iTag, ref bit [InstWay_bits-1:0] Instruction_ways); // Allocacte Cache Line in INSTRUCTION CACHE
	L1_INSTRUCTION_Cache[iIndex][Instruction_ways].TagBits = iTag;
	UpdateLRUBits_ins(iIndex, Instruction_ways);
endtask

//--------------------------------------------------------------------------------------------------------------------------------------------------
//Eviction Line task
//--------------------------------------------------------------------------------------------------------------------------------------------------

task automatic Eviction_Data (logic [IndexBits -1:0] iIndex, ref bit [DataWay_bits-1:0] Data_ways);
	for (int i =0; i< DataWay; i++ )
		if( L1_DATA_Cache[iIndex][i].LRU_bits ==  '0 )
		begin
			if( Mode==1 && (L1_DATA_Cache[iIndex][i].MESI_bits == Modified) )
				$display("Write to L2 address        %d'h%h" ,AddressBits,Address);
			Data_ways = i;
		end
endtask

task automatic Eviction_Inst (logic [IndexBits - 1:0] iIndex, ref bit [InstWay_bits-1:0] Instruction_ways);
	for (int i =0; i< InstWay; i++ )
		if( L1_INSTRUCTION_Cache[iIndex][i].LRU_bits == '0 )
		begin
			if( Mode==1 && (L1_INSTRUCTION_Cache[iIndex][i].MESI_bits == Modified) )
					$display("Write to L2 address        %d'h%h" ,AddressBits,Address);				
			Instruction_ways = i;
		end
endtask

//-------------------------------------------------------------------------------------------------------------------------------------------
//Updating LRU Bits
//-------------------------------------------------------------------------------------------------------------------------------------------

task automatic UpdateLRUBits_data(logic [IndexBits-1:0]iIndex, ref bit [DataWay_bits-1:0] Data_ways ); // Update LRU bits in DATA CACHE
	logic [DataWay_bits-1:0]temp;
	temp = L1_DATA_Cache[iIndex][Data_ways].LRU_bits;
	
	for (int j = 0; j < DataWay ; j++)
		L1_DATA_Cache[iIndex][j].LRU_bits = (L1_DATA_Cache[iIndex][j].LRU_bits > temp) ? L1_DATA_Cache[iIndex][j].LRU_bits - 1'b1 : L1_DATA_Cache[iIndex][j].LRU_bits;
			
	L1_DATA_Cache[iIndex][Data_ways].LRU_bits = '1;
endtask 

task automatic UpdateLRUBits_ins(logic [IndexBits-1:0]iIndex, ref bit [InstWay_bits-1:0] Instruction_ways ); // Update LRU bits in INSTRUCTION CACHE
	logic [InstWay_bits-1:0]temp;
	temp = L1_INSTRUCTION_Cache[iIndex][Instruction_ways].LRU_bits;
	
	for (int j = 0; j < InstWay ; j++)
		L1_INSTRUCTION_Cache[iIndex][j].LRU_bits = (L1_INSTRUCTION_Cache[iIndex][j].LRU_bits > temp) ? L1_INSTRUCTION_Cache[iIndex][j].LRU_bits - 1'b1 : L1_INSTRUCTION_Cache[iIndex][j].LRU_bits;
	
	L1_INSTRUCTION_Cache[iIndex][Instruction_ways].LRU_bits = '1;
endtask 

//-------------------------------------------------------------------------------------------------------------------------------------------
//To Print Cache contents and MESI States
//-------------------------------------------------------------------------------------------------------------------------------------------

task Print_CacheContents_MESIstates();		
	$display("********************************************************************************************************************************");
	$display("****************************** DATA CACHE CONTENTS AND MESI STATES *************************************************************");
	
	for(int i=0; i< Sets; i++)
	begin
		for(int j=0; j< DataWay; j++) 
			if(L1_DATA_Cache[i][j].MESI_bits != Invalid)
			begin
				if(!Flag)
				begin
					$display("Index = %d'h%h\n", IndexBits , i );
					Flag = 1;
				end
				$display(" Way = %d \n Tag = %d'h%h \n MESI = %s \n LRU = %d'b%b", j,TagBits,L1_DATA_Cache[i][j].TagBits, L1_DATA_Cache[i][j].MESI_bits,DataWay_bits,L1_DATA_Cache[i][j].LRU_bits);
			end
		Flag = 0;
	end
	$display("____________________________________END OF DATA CACHE_________________________________________________________________________\n\n");
	$display("************************* INSTRUCTION CACHE CONTENTS AND MESI STATES ***********************************************************");
	for(int i=0; i< Sets; i++)
	begin
		for(int j=0; j< InstWay; j++) 
			if(L1_INSTRUCTION_Cache[i][j].MESI_bits != Invalid)
			begin
				if(!Flag)
				begin
					$display("Index = %d'h%h\n",IndexBits,i);
					Flag = 1;
				end
				$display(" Way = %d \n Tag = %d'h%h \n MESI = %s \n LRU = %d'b%b", j,TagBits, L1_INSTRUCTION_Cache[i][j].TagBits, L1_INSTRUCTION_Cache[i][j].MESI_bits,InstWay_bits,L1_INSTRUCTION_Cache[i][j].LRU_bits);
			end
		Flag = 0;
	end
	$display("____________________________________END OF INSTRUCTION CACHE________________________________________________________________________\n\n");
endtask

//-------------------------------------------------------------------------------------------------------------------------------------------
//Clear cache
//-------------------------------------------------------------------------------------------------------------------------------------------

task ClearCache();
Data_CacheHITcount 	= 0;
Data_CacheMISScount 	= 0;
Data_CacheREADcount 	= 0;
Data_CacheWRITEcount    = 0;
	
Inst_CacheHITcount	= 0;
Inst_CacheMISScount 	= 0;
Inst_CacheREADcount 	= 0;
fork
for(int i=0; i< Sets; i++) 
		for(int j=0; j< DataWay; j++) 
			L1_DATA_Cache[i][j].MESI_bits = Invalid;

	for(int i=0; i< Sets; i++) 
		for(int j=0; j< InstWay; j++) 
			L1_INSTRUCTION_Cache[i][j].MESI_bits = Invalid;
join
endtask

endmodule

