use syn::{parse::ParseStream, Error, LitBool, LitInt, LitStr, Token};

/// Parsed circuit attributes from the #[cosmwasm_circuit(...)] macro
///
/// ## Required Attributes
/// - `k`: Circuit size parameter (2^k rows), must be in range [11, 20]
/// - `instances`: Number of public inputs, must be in range [1, 255]
///
/// ## Optional Attributes
/// - `circuit_type`: Serialization format variant (default: "Plonkish")
/// - `footer_version`: Footer format version (default: 2)
/// - `analyze_cs`: Whether to perform CS analysis (default: true)
#[derive(Debug, Clone)]
pub struct CircuitAttributes {
    /// Circuit size parameter (2^k rows)
    pub k: u32,
    /// Number of public inputs (instance count)
    pub instances: u8,
    /// Circuit type identifier for serialization
    pub circuit_type: CircuitTypeAttr,
    /// Footer format version (1 = original, 2 = CS-inclusive)
    pub footer_version: u8,
    /// Whether to perform constraint system analysis
    pub analyze_cs: bool,
}

/// Circuit type attribute values
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CircuitTypeAttr {
    /// Plonkish circuit type (halo2)
    #[default]
    Plonkish,
}

impl CircuitTypeAttr {
    /// Convert to u8 for serialization
    pub fn to_u8(self) -> u8 {
        match self {
            CircuitTypeAttr::Plonkish => 0,
        }
    }

    /// Parse from string
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "Plonkish" | "plonkish" => Some(CircuitTypeAttr::Plonkish),
            _ => None,
        }
    }
}

impl syn::parse::Parse for CircuitAttributes {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let mut k: Option<u32> = None;
        let mut instances: Option<u8> = None;
        let mut circuit_type = CircuitTypeAttr::default();
        let mut footer_version: u8 = 2;
        let mut analyze_cs: bool = true;

        // Parse comma-separated key=value pairs
        loop {
            if input.is_empty() {
                break;
            }

            let ident = input.parse::<syn::Ident>()?;
            input.parse::<Token![=]>()?;

            match ident.to_string().as_str() {
                "k" => {
                    if k.is_some() {
                        return Err(Error::new_spanned(&ident, "Duplicate attribute: k"));
                    }
                    let lit = input.parse::<LitInt>()?;
                    k = Some(lit.base10_parse::<u32>()?);
                }
                "instances" => {
                    if instances.is_some() {
                        return Err(Error::new_spanned(&ident, "Duplicate attribute: instances"));
                    }
                    let lit = input.parse::<LitInt>()?;
                    instances = Some(lit.base10_parse::<u8>()?);
                }
                // Support legacy 'i' attribute for backward compatibility
                "i" => {
                    if instances.is_some() {
                        return Err(Error::new_spanned(
                            &ident,
                            "Duplicate attribute: i/instances",
                        ));
                    }
                    let lit = input.parse::<LitInt>()?;
                    instances = Some(lit.base10_parse::<u8>()?);
                }
                "circuit_type" => {
                    let lit = input.parse::<LitStr>()?;
                    circuit_type = CircuitTypeAttr::from_str(&lit.value()).ok_or_else(|| {
                        Error::new_spanned(
                            &lit,
                            format!(
                                "Unknown circuit_type '{}'. Valid types: Plonkish",
                                lit.value()
                            ),
                        )
                    })?;
                }
                "footer_version" => {
                    let lit = input.parse::<LitInt>()?;
                    footer_version = lit.base10_parse::<u8>()?;
                }
                "analyze_cs" => {
                    let lit = input.parse::<LitBool>()?;
                    analyze_cs = lit.value();
                }
                _ => {
                    return Err(Error::new_spanned(
                        &ident,
                        format!(
                            "Unknown attribute: {}. Valid attributes: k, instances, circuit_type, footer_version, analyze_cs",
                            ident
                        ),
                    ));
                }
            }

            // Check for comma
            if input.is_empty() {
                break;
            }
            input.parse::<Token![,]>()?;
        }

        // Validate required attributes
        let k = k.ok_or_else(|| Error::new(input.span(), "Missing required attribute: k"))?;
        let instances = instances.ok_or_else(|| {
            Error::new(input.span(), "Missing required attribute: instances (or i)")
        })?;

        Ok(CircuitAttributes {
            k,
            instances,
            circuit_type,
            footer_version,
            analyze_cs,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use quote::quote;

    #[test]
    fn parse_minimal_attributes() {
        let tokens = quote! { k = 17, instances = 2 };
        let attrs: CircuitAttributes = syn::parse2(tokens).unwrap();
        assert_eq!(attrs.k, 17);
        assert_eq!(attrs.instances, 2);
        assert_eq!(attrs.circuit_type, CircuitTypeAttr::Plonkish);
        assert_eq!(attrs.footer_version, 2);
        assert!(attrs.analyze_cs);
    }

    #[test]
    fn parse_full_attributes() {
        let tokens = quote! {
            k = 14,
            instances = 4,
            circuit_type = "Plonkish",
            footer_version = 2,
            analyze_cs = false
        };
        let attrs: CircuitAttributes = syn::parse2(tokens).unwrap();
        assert_eq!(attrs.k, 14);
        assert_eq!(attrs.instances, 4);
        assert_eq!(attrs.circuit_type, CircuitTypeAttr::Plonkish);
        assert_eq!(attrs.footer_version, 2);
        assert!(!attrs.analyze_cs);
    }

    #[test]
    fn parse_legacy_i_attribute() {
        let tokens = quote! { k = 17, i = 3 };
        let attrs: CircuitAttributes = syn::parse2(tokens).unwrap();
        assert_eq!(attrs.instances, 3);
    }

    #[test]
    fn missing_k_errors() {
        let tokens = quote! { instances = 2 };
        let result: syn::Result<CircuitAttributes> = syn::parse2(tokens);
        assert!(result.is_err());
    }

    #[test]
    fn missing_instances_errors() {
        let tokens = quote! { k = 17 };
        let result: syn::Result<CircuitAttributes> = syn::parse2(tokens);
        assert!(result.is_err());
    }

    #[test]
    fn unknown_circuit_type_errors() {
        let tokens = quote! { k = 17, instances = 2, circuit_type = "Unknown" };
        let result: syn::Result<CircuitAttributes> = syn::parse2(tokens);
        assert!(result.is_err());
    }
}
