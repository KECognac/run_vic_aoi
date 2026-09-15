# Citing this data

The VIC parameter files this pipeline downloads (`source_urls$livneh_params_base`
in `config.yml`) come from the Livneh Hydrology Research Group:
<https://ciresgroups.colorado.edu/livneh/data/variable-infiltration-capacity-vic-model-parameters-116deg>

Per that page, cite the following if you use this data (required citation
first, optional/supporting citations after):

> Livneh B., E.A. Rosenberg, C. Lin, B. Nijssen, V. Mishra, K.M. Andreadis,
> E.P. Maurer, and D.P. Lettenmaier, 2013: A Long-Term Hydrologically Based
> Dataset of Land Surface Fluxes and States for the Conterminous United
> States: Update and Extensions. *Journal of Climate*, 26, 9384-9392.
>
> Maurer E. P., A.W. Wood, J.C. Adam, D.P. Lettenmaier, and B. Nijssen,
> 2002: A Long-Term Hydrologically Based Dataset of Land Surface Fluxes and
> States for the Conterminous United States. *Journal of Climate*, 15,
> 3237-3251.

You may also consider citing:

> Zhu, C., T. Cavazos, and D.P. Lettenmaier, 2007: Role of antecedent land
> surface conditions in warm season precipitation over northwestern Mexico.
> *Journal of Climate*, 20(9), 1774-1791.
>
> Tang, Q., E.R. Vivoni, F. Munoz-Arriola, and D.P. Lettenmaier, 2012:
> Predictability of evapotranspiration patterns using remotely sensed
> vegetation dynamics during the North American monsoon. *Journal of
> Hydrometeorology*, 13(1), 103-121.

If a separate forcing dataset ends up getting used (once
`source_urls$livneh_forcing_base` is confirmed -- see `R/04_download_forcing.R`),
check whether its source page lists its own citation requirement; forcing
and parameters are documented on separate pages of the same site and may
not share an identical citation list.
