#include <cuda.h>
#include <stdio.h>
#include "datadef.h"
#include "wfloat3.h"
#include "warp_device.cuh"
#include "check_cuda.h"


__global__ void scatter_multi_kernel(unsigned N, unsigned starting_index, cross_section_data* d_xsdata, particle_data* d_particles, unsigned* d_remap){    

	// declare shared variables
	//__shared__ 	unsigned			n_isotopes;				
	//__shared__ 	unsigned			energy_grid_len;		
	//__shared__ 	unsigned			total_reaction_channels;
	//__shared__ 	unsigned*			rxn_numbers;			
	//__shared__ 	unsigned*			rxn_numbers_total;		
	//__shared__ 	float*				energy_grid;			
	//__shared__ 	float*				rxn_Q;						
	//__shared__ 	float*				xs;	
	__shared__ 	float*				awr;
	//__shared__ 	float*				temp;
	__shared__ 	dist_container*		dist_scatter;
	__shared__ 	dist_container*		dist_energy; 
	__shared__	spatial_data*		space;	
	__shared__	unsigned*			rxn;	
	__shared__	float*				E;		
	__shared__	float*				Q;		
	__shared__	unsigned*			rn_bank;
	//__shared__	unsigned*			cellnum;
	//__shared__	unsigned*			matnum;	
	__shared__	unsigned*			isonum;	
	//__shared__	unsigned*			yield;	
	__shared__	float*				weight;	
	__shared__	unsigned*			index;	

	// have thread 0 of block copy all pointers and static info into shared memory
	if (threadIdx.x == 0){
		//n_isotopes					= d_xsdata[0].n_isotopes;								
		//energy_grid_len				= d_xsdata[0].energy_grid_len;				
		//total_reaction_channels		= d_xsdata[0].total_reaction_channels;
		//rxn_numbers 				= d_xsdata[0].rxn_numbers;						
		//rxn_numbers_total			= d_xsdata[0].rxn_numbers_total;					
		//energy_grid 				= d_xsdata[0].energy_grid;						
		//rxn_Q 						= d_xsdata[0].Q;												
		//xs 							= d_xsdata[0].xs;												
		awr 						= d_xsdata[0].awr;										
		//temp 						= d_xsdata[0].temp;										
		dist_scatter 				= d_xsdata[0].dist_scatter;						
		dist_energy 				= d_xsdata[0].dist_energy; 
		space						= d_particles[0].space;
		rxn							= d_particles[0].rxn;
		E							= d_particles[0].E;
		Q							= d_particles[0].Q;	
		rn_bank						= d_particles[0].rn_bank;
		//cellnum						= d_particles[0].cellnum;
		//matnum						= d_particles[0].matnum;
		isonum						= d_particles[0].isonum;
		//yield						= d_particles[0].yield;
		weight						= d_particles[0].weight;
		index						= d_particles[0].index;
	}

	// make sure shared loads happen before anything else
	__syncthreads();

	// return immediately if out of bounds
	int tid_in = threadIdx.x+blockIdx.x*blockDim.x;
	if (tid_in >= N){return;}  

	//remap to active
	int tid				=	d_remap[starting_index + tid_in];
	unsigned this_rxn 	=	rxn[    starting_index + tid_in];

	// print and return if wrong
	if ( this_rxn < 11 | this_rxn > 45 ){printf("multiplicity scattering kernel accessing wrong reaction @ dex %u rxn %u\n",tid, this_rxn);return;} 

	// check data pointers
	if( dist_energy == 0x0 | dist_scatter == 0x0 ){
		printf("null pointer, energy/scatter array in multiplicity scatter!,tid %u rxn %u\n",tid,this_rxn);
		return;
	}

	//constants
	//const float  	pi			=   3.14159265359;
	const float  	m_n			=   1.00866491600;		// u
	//const float		kb			=	8.617332478e-11;	// MeV/k

	// load history data
	wfloat3		hats_old(space[tid].xhat,space[tid].yhat,space[tid].zhat);
	unsigned	this_tope		=	isonum[  tid];
	unsigned	this_dex		=	index[   tid];
	float		this_E			=	E[       tid];
	float		this_weight		=	weight[  tid];
	float		this_Q			=	Q[       tid];
	unsigned	rn				=	rn_bank[ tid];
	float		this_awr		=	awr[ this_tope];
	//float		this_temp		=	temp[this_tope];

	// pick upper or lower via stochastic mixing
	dist_data	this_edist, this_sdist;
	dist_data	sdist_lower	=	dist_scatter[this_dex].lower[0];
	dist_data	sdist_upper	=	dist_scatter[this_dex].upper[0];
	dist_data	edist_lower	=	dist_energy[ this_dex].lower[0];
	dist_data	edist_upper	=	dist_energy[ this_dex].upper[0];

	unsigned	this_law;
	float		f			=	(this_E - edist_lower.erg) / (edist_upper.erg - edist_lower.erg);
	if( get_rand(&rn)>f ){
		this_edist	=	edist_lower;
		this_sdist	=	sdist_lower;
	}
	else{
		this_edist = edist_upper;
		this_sdist = sdist_upper;
	}
	this_law	=	this_edist.law;

	// internal kernel variables
	float  		E_target     		=   0;
	float 		speed_target     	=   sqrtf(2.0*E_target/(this_awr*m_n));
	float  		speed_n          	=   sqrtf(2.0*this_E/m_n);
	float 		E_new				=   0.0;
	float 		sampled_E			=	0.0;
	wfloat3 	v_n_cm, v_t_cm, v_n_lf, v_t_lf, v_cm, hats_new, hats_target, rotation_hat;
	float 		mu, E0, A, R;
	unsigned 	dist_index[1];

	// ensure normalization
	hats_old = hats_old / hats_old.norm2();

	// make speed vectors, assume high enough energy to approximate target as stationary
	v_n_lf = hats_old    * speed_n;
	v_t_lf = hats_target * 0.0;

	// calculate  v_cm
	v_cm = (v_n_lf + (v_t_lf*this_awr))/(1.0+this_awr);

	//transform neutron velocity into CM frame
	v_n_cm = v_n_lf - v_cm;
	v_t_cm = v_t_lf - v_cm;

	if ( this_law == 4 ){

		// sample continuous tabular
		E0 = sample_continuous_tablular( 	this_edist.len , 
											this_edist.intt , 
											get_rand(&rn) , 
											this_edist.var , 
											this_edist.cdf, 
											this_edist.pdf );
		//scale it to bins 
		sampled_E = scale_to_bins(	f, E0, 
									 this_edist.var[0],  this_edist.var[ this_edist.len-1], 
									edist_lower.var[0], edist_lower.var[edist_lower.len-1], 
									edist_upper.var[0], edist_upper.var[edist_upper.len-1] );

		// sample mu isotropically
		mu  = 2.0*get_rand(&rn)-1.0;

	}
	else if ( this_law == 9 ){   // evaporation spectrum
	
		// get tabulated temperature
		float t0 = edist_lower.var[0];
		float t1 = edist_upper.var[0];
		float U  = edist_lower.cdf[0];
		float e0 = edist_lower.erg;
		float e1 = edist_upper.erg;
		float  T = 0.0;
		float  m = 0.0;
	
		// interpolate T
		if (e1==e0 | edist_lower.intt==1){ 
			T = t0;
		}
		else if (edist_lower.intt==2){// lin-lin interpolation
			T  = (t1 - t0)/(e1 - e0) * (this_E - e0) + t0;
		}
		else{
			printf("dont know what to do!\n");
		}
	
		// rejection sample
		m  = (this_E - U)/T;
		e0 = 1.0-expf(-m);
		float x  = -logf(1.0-e0*get_rand(&rn)) - logf(1.0-e0*get_rand(&rn));
		while (  x>m ) {
			x  = -logf(1.0-e0*get_rand(&rn)) - logf(1.0-e0*get_rand(&rn));
		}
	
		// mcnp5 volIII pg 2-43
		sampled_E = T * x;
	
		// isotropic mu
		mu  = 2.0*get_rand(&rn)-1.0;
	
	}
	else if ( this_law == 44 ){

		// make sure scatter array is present
		if(dist_scatter == 0x0){
			printf("null pointer, scatter array in continuum !,dex %u rxn %u tope %u E %6.4E \n",this_dex,this_rxn,this_tope,this_E);
			return;
		}

		// compute interpolation factor
		if(f<0){
			printf("DATA NOT WITHIN ENERGY INTERVAL tid %u rxn %u\n",tid,this_rxn);
		}

		// sample tabular on energy, but get index as well as value
		E0 = sample_continuous_tablular( 	dist_index ,
											this_edist.len , 
											this_edist.intt , 
											get_rand(&rn) , 
											this_edist.var , 
											this_edist.cdf, 
											this_edist.pdf );

		//scale it to bins 
		sampled_E = scale_to_bins(	f, E0, 
									 this_edist.var[0],  this_edist.var[ this_edist.len-1], 
									edist_lower.var[0], edist_lower.var[edist_lower.len-1], 
									edist_upper.var[0], edist_upper.var[edist_upper.len-1] );

		// find correlated mu
		if (this_sdist.intt==1){
			A	=	this_sdist.var[dist_index[0]];
			R	=	this_sdist.cdf[dist_index[0]];
		}
		else if (this_sdist.intt==2){
			A	=	interpolate_linear_energy(	E0,
												this_edist.var[dist_index[0]],
												this_edist.var[dist_index[0]+1],
												this_sdist.var[dist_index[0]],
												this_sdist.var[dist_index[0]+1]);
			R	=	interpolate_linear_energy(	E0,
												this_edist.var[dist_index[0]],
												this_edist.var[dist_index[0]+1],
												this_sdist.cdf[dist_index[0]],
												this_sdist.cdf[dist_index[0]+1]);
		}
		else{
			printf("INTT=%u NOT HANDLED in law %u of multiplicity scatter!",this_sdist.law,this_sdist.intt);
		}

		float rn1 	= get_rand(&rn);
		if( get_rand(&rn)>R ){
			float T = (2.0*rn1-1.0)*sinhf(A);
			mu		= logf(T+sqrtf(T*T+1.0))/A;
		}
		else{
			mu		= logf(rn1*expf(A)+(1.0-rn1)*expf(-A))/A;
		}

	}
	else if ( this_law == 61 ){

		// sample continuous tabular, 61 returns the the proper index depending on intt type for law 61
		E0 = sample_continuous_tablular61( 	dist_index ,        
											this_edist.len , 
											this_edist.intt , 
											get_rand(&rn) , 
											this_edist.var , 
											this_edist.cdf, 
											this_edist.pdf );
		//scale it to bins 
		sampled_E = scale_to_bins(	f, E0, 
									 this_edist.var[0],  this_edist.var[ this_edist.len-1], 
									edist_lower.var[0], edist_lower.var[edist_lower.len-1], 
									edist_upper.var[0], edist_upper.var[edist_upper.len-1] );

		// get position of data in vector and vector length
		unsigned ang_position	=	(unsigned) this_sdist.pdf[dist_index[0]];
		unsigned this_len		=	(unsigned) this_sdist.pdf[dist_index[0]+1] - (unsigned) this_sdist.pdf[dist_index[0]];

		// sample mu from corresponding distribution
		mu = sample_continuous_tablular(	this_len , 
											this_sdist.intt , 
											get_rand(&rn) , 
											&this_sdist.cdf[ ang_position                    ] , 
											&this_sdist.cdf[ ang_position +   this_sdist.len ] , 
											&this_sdist.cdf[ ang_position + 2*this_sdist.len ] );

	}
	else if ( this_law == 66 ){

		// get tabulated temperature
		//unsigned 	nbodies 	= 	3;                   // assume ONLY FOR 1002 n,2n!
		unsigned 	this_yield1 = 	2;                   // assume ONLY FOR 1002 n,2n!
		float		A			=	2.9986199999999998;  // assume ONLY FOR 1002 n,2n!
		// if (nbodies>3) {printf("nbodies in law 66  is greater than 3!!!\n");}

		// calculate things...
		float Emax 		= (this_yield1-1.0)/this_yield1 * (A/(A+1)*this_E + this_Q); 
		float rn1       = get_rand(&rn);
		float rn2       = get_rand(&rn);
		float rn3       = get_rand(&rn);
		float rn4       = get_rand(&rn);

		// rejection sample random numbers
		while ( (rn1*rn1 + rn2*rn2) > 1.0 ){
			rn1 = get_rand(&rn);
			rn2 = get_rand(&rn);
		}
		while ( (rn3*rn3 + rn4*rn4) > 1.0 ){
			rn3 = get_rand(&rn);
			rn4 = get_rand(&rn);
		}

		float x = -rn1 * logf(rn1*rn1 + rn2*rn2)/ (rn1*rn1 + rn2*rn2) - logf(get_rand(&rn)) ;
		float y = -rn3 * logf(rn3*rn3 + rn4*rn4)/ (rn3*rn3 + rn4*rn4) - logf(get_rand(&rn)) ;

		//  calculate mu
		sampled_E = Emax * x /( x + y );

		// isotropic mu
		mu  = 2.0*get_rand(&rn)-1.0;

	}
	else{

		printf("LAW %u NOT HANDLED IN MULTIPLICITY SCATTER!  rxn %u\n",this_law,this_rxn);

	}

	// rotate direction vector
	hats_old = v_n_cm / v_n_cm.norm2();
	hats_old = hats_old.rotate(mu, get_rand(&rn));

	//  scale to sampled energy
	v_n_cm = hats_old * sqrtf(2.0*sampled_E/m_n);
	
	// transform back to L
	v_n_lf = v_n_cm + v_cm;
	hats_new = v_n_lf / v_n_lf.norm2();
	hats_new = hats_new / hats_new.norm2(); // get higher precision, make SURE vector is length one
	
	// calculate energy in lab frame
	E_new = 0.5 * m_n * v_n_lf.dot(v_n_lf);

	// check errors
	if (!isfinite(sampled_E) | sampled_E < 0.0){
		printf("Multiplicity scatter mis-sampled tid %i data_dex %u E %6.4E... \n",tid_in,tid,sampled_E);
	}
	if (!isfinite(mu) | mu < -1.0 | mu > 1.0){
		printf("Multiplicity scatter mis-sampled tid %i data_dex %u mu %6.4E... \n",tid_in,tid,mu);
	}

	// multiply weight by multiplicity
	if(     this_rxn == 22 | this_rxn == 23 | this_rxn == 28 | this_rxn == 29 | this_rxn == 32 | this_rxn == 33 | this_rxn == 34 | this_rxn == 35 | this_rxn == 36 | this_rxn == 44 | this_rxn == 45){
		this_weight = this_weight * 1.0;
	}
	else if(this_rxn == 11 | this_rxn == 16 | this_rxn == 24 | this_rxn == 30 | this_rxn == 41){
		this_weight = this_weight * 2.0;
	}
	else if(this_rxn == 17 | this_rxn == 25 | this_rxn == 42){
		this_weight = this_weight * 3.0;
	}
	else if(this_rxn == 37){
		this_weight = this_weight * 4.0;
	}
	else{
		printf("UNKNOWN MT NUMBER %u IN MULTIPLICITY\n",this_rxn);
	}


	//printf("tid %d law %u sampled_E %6.4E mu %6.4E weight %6.4E\n",tid,this_law,sampled_E,mu,this_weight);
	
	// write results
	E[      tid]	=	E_new;
	rn_bank[tid]	=	rn;
	weight[ tid]	=	this_weight;
	space[tid].xhat	=	hats_new.x;
	space[tid].yhat	=	hats_new.y;
	space[tid].zhat	=	hats_new.z;



}

/**
 * \brief a
 * \details b
 *
 * @param[in]    stream          - CUDA stream to launch the kernel on
 * @param[in]    NUM_THREADS     - the number of threads to run per thread block
 * @param[in]    N               - the total number of threads to launch on the grid for multiplicity scattering
 * @param[in]    starting_index  - starting index of the multiplicity scatter block in the remap vector
 * @param[in]    d_xsdata        - device pointer to cross section data pointer array 
 * @param[in]    d_particles     - device pointer to particle data pointer array 
 * @param[in]    d_remap         - device pointer to data remapping vector
 */ 
void scatter_multi( cudaStream_t stream, unsigned NUM_THREADS, unsigned N, unsigned starting_index, cross_section_data* d_xsdata, particle_data* d_particles, unsigned* d_remap){

	if(N<1){return;}
	unsigned blks = ( N + NUM_THREADS - 1 ) / NUM_THREADS;
	
	scatter_multi_kernel <<< blks, NUM_THREADS , 0 , stream >>> ( N, starting_index, d_xsdata, d_particles, d_remap );
	check_cuda(cudaThreadSynchronize());

}

